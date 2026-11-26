"""Hermes' side of the homelab's long-term memory.

The memory itself is the Rust `memory` service on lugh (modules/features/agent-tools/memory): SQLite holds items,
summaries of past conversations and the exchanges themselves, and Qdrant searches them by meaning. It serves MCP over
HTTP without sessions, so every call here is one JSON-RPC POST. This provider only connects Hermes' turn hooks to it:

- system_prompt_block: how memory works and the core items, taken once when a conversation starts (Hermes keeps the
  system prompt fixed, which keeps the model's cache).
- prefetch: memories relevant to the owner's message, attached to it as <memories>.
- sync_turn: each answered exchange stored, in the background. The service consolidates a conversation once it has
  been quiet for half an hour; on_session_end asks for that at once.
- tools: the service's model-facing tools, named memory_<tool>, with the service's own descriptions and schemas.

Subagents get no memory at all. Scheduled jobs may use the tools (the morning check, open threads) but their turns
aren't stored, since they aren't the owner talking.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Optional

from agent.memory_provider import MemoryProvider, spawn_context_thread
from tools.registry import tool_error

logger = logging.getLogger(__name__)

URL = os.environ.get("COSMOS_MEMORY_URL", "http://127.0.0.1:8095/mcp")
PREFIX = "memory_"
# The tools the model gets; the rest (auto_recall, index_exchange, consolidate, …) are this provider's own.
MODEL_TOOLS = ("recall", "get", "list", "remember", "update", "retract", "stale_threads", "changes", "undo_change")
# Hermes gives prefetch 8 s; the service's auto-recall takes 1-3 s.
RECALL_TIMEOUT = 5.0
CALL_TIMEOUT = 60.0
# Consolidation asks the helper model to read a whole conversation.
CONSOLIDATE_TIMEOUT = 600.0


class MemoryServiceError(Exception):
    pass


def _rpc(method: str, params: dict[str, Any], timeout: float) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        URL,
        data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            reply = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        raise MemoryServiceError(f"the memory service didn't answer: {e}") from e
    if "error" in reply:
        raise MemoryServiceError(reply["error"].get("message", str(reply["error"])))
    return reply.get("result")


def _call(tool: str, arguments: dict[str, Any], timeout: float = CALL_TIMEOUT) -> dict[str, Any]:
    """One tool call; the service's structured result, or its error as an exception."""
    result = _rpc("tools/call", {"name": tool, "arguments": arguments}, timeout) or {}
    value = result.get("structuredContent")
    if value is None:
        text = "".join(part.get("text", "") for part in result.get("content", []) if part.get("type") == "text")
        value = json.loads(text) if text else {}
    if isinstance(value, dict) and "error" in value and len(value) <= 2:
        raise MemoryServiceError(value["error"])
    return value


def _label(hit: dict[str, Any]) -> str:
    if hit.get("type") == "item":
        status = f", {hit['status'].replace('_', ' ')}" if hit.get("status") else ""
        return f"#{hit['id']} {hit.get('kind') or 'item'}{status}"
    return "past session" if hit.get("type") == "topic" else "past conversation"


def memories_block(hits: list[dict[str, Any]]) -> str:
    lines = "\n".join(f"- {_label(h)} ({h.get('date', '')}): {h.get('content', '')}" for h in hits)
    return f"<memories>\n{lines}\n</memories>"


def _profile(hermes_home: Optional[str]) -> str:
    """The Hermes profile a conversation runs in: "default", or the name under ~/.hermes/profiles/."""
    if not hermes_home:
        return "default"
    parts = Path(hermes_home).parts
    return parts[parts.index("profiles") + 1] if "profiles" in parts[:-1] else "default"


class CosmosMemoryProvider(MemoryProvider):
    def __init__(self) -> None:
        self._session_id = ""
        self._room = ""
        self._context = "primary"
        self._tags: list[str] = []
        self._previous: Optional[str] = None
        self._schemas: Optional[list[dict[str, Any]]] = None
        self._core: Optional[str] = None

    @property
    def name(self) -> str:
        return "nix-managed-cosmos-memory"

    def is_available(self) -> bool:
        # No network here (Hermes' rule); a service that's down shows as failed calls instead.
        return True

    def get_config_schema(self) -> list[dict[str, Any]]:
        return []

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = session_id
        self._room = f"hermes:{session_id}"
        self._context = kwargs.get("agent_context") or "primary"
        profile = _profile(kwargs.get("hermes_home"))
        # A profile of its own (such as campaign) labels what comes from it, as campaign chats did.
        self._tags = [] if profile == "default" else [profile]

    @property
    def _owner_talking(self) -> bool:
        return self._context == "primary"

    def system_prompt_block(self) -> str:
        if self._context == "subagent":
            return ""
        if self._core is None:
            try:
                self._core = _call("core_block", {}, timeout=RECALL_TIMEOUT).get("text", "")
            except MemoryServiceError as e:
                logger.warning("cosmos-memory: no core block for this conversation: %s", e)
                return ""
        return self._core

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if not self._owner_talking or not query.strip():
            return ""
        arguments: dict[str, Any] = {"message": query, "room": self._room}
        if self._previous:
            arguments["previous"] = self._previous
        try:
            hits = _call("auto_recall", arguments, timeout=RECALL_TIMEOUT).get("hits", [])
        except MemoryServiceError as e:
            logger.warning("cosmos-memory: auto-recall failed: %s", e)
            return ""
        return memories_block(hits) if hits else ""

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "", messages=None, **_) -> None:
        if not self._owner_talking or not user_content.strip() or not assistant_content.strip():
            return
        arguments: dict[str, Any] = {
            "room": self._room,
            # Unique per turn: the service stores the same event only once.
            "event": f"{self._session_id}:{uuid.uuid4()}",
            "message": user_content,
            "answer": assistant_content,
            "tags": self._tags,
        }
        if self._previous:
            arguments["previous"] = self._previous
        self._previous = user_content

        def store() -> None:
            try:
                _call("index_exchange", arguments)
            except MemoryServiceError as e:
                logger.warning("cosmos-memory: storing an exchange failed: %s", e)

        spawn_context_thread(store, name="cosmos-memory-exchange").start()

    def on_session_end(self, messages: list[dict[str, Any]]) -> None:
        if not self._owner_talking:
            return
        room = self._room

        def consolidate() -> None:
            try:
                _call("consolidate", {"room": room}, timeout=CONSOLIDATE_TIMEOUT)
            except MemoryServiceError as e:
                # The service consolidates quiet conversations on its own, so this is only a head start.
                logger.info("cosmos-memory: consolidating at session end failed (the service retries): %s", e)

        spawn_context_thread(consolidate, name="cosmos-memory-consolidate").start()

    def get_tool_schemas(self) -> list[dict[str, Any]]:
        if self._context == "subagent":
            return []
        if self._schemas is None:
            try:
                tools = (_rpc("tools/list", {}, timeout=RECALL_TIMEOUT) or {}).get("tools", [])
            except MemoryServiceError as e:
                logger.warning("cosmos-memory: no memory tools for this conversation: %s", e)
                return []
            schemas = []
            for tool in tools:
                if tool.get("name") not in MODEL_TOOLS:
                    continue
                parameters = dict(tool.get("inputSchema") or {"type": "object", "properties": {}})
                parameters.pop("$schema", None)
                schemas.append(
                    {"name": PREFIX + tool["name"], "description": tool.get("description", ""), "parameters": parameters}
                )
            self._schemas = schemas
        return self._schemas

    def handle_tool_call(self, tool_name: str, args: dict[str, Any], **kwargs) -> str:
        tool = tool_name.removeprefix(PREFIX)
        if tool not in MODEL_TOOLS or self._context == "subagent":
            return tool_error(f"Unknown tool: {tool_name}")
        try:
            return json.dumps(_call(tool, args or {}), ensure_ascii=False)
        except MemoryServiceError as e:
            return tool_error(str(e))


def register(ctx) -> None:
    # A new instance on every load: a gateway serving several profiles loads providers more than once.
    ctx.register_memory_provider(CosmosMemoryProvider())
