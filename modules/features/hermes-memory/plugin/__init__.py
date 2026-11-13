"""Hermes' side of lugh's memory service.

The service holds the memories and the wiki index. This plugin gives the agent tools for them and
tells the service who is asking: the platform of the chat, and whether the caller is the owner's own
chat at all. Hermes passes each tool call its session, and the session hooks below say which
sessions are subagents and which platform the rest are on.

- Subagents, including research subagents on Claude, never see memories. They may search the wiki.
- A session this plugin hasn't seen is refused, so a gap fails closed.
- Local-only memories are kept off chats that pass through someone else's servers, such as Telegram.
- After each turn in the owner's own chats, the exchange goes to the service, whose worker model saves
  anything worth remembering. Subagents, scheduled jobs and webhooks aren't the owner talking, so they're skipped.
"""

import http.client
import json
import logging
import os
import socket
import threading

logger = logging.getLogger(__name__)

SOCKET = os.environ.get("HERMES_MEMORY_SOCKET", "/run/hermes-memory/api.sock")
TOOLSET = "knowledge"
# Hermes Desktop and the terminal UI report "tui". These reach lugh directly, over NetBird.
LOCAL_PLATFORMS = {"tui", "cli", "local"}
KINDS = ["fact", "preference", "procedure", "event", "commitment"]
# Turns on these platforms aren't the owner talking.
NOT_OWNER_PLATFORMS = {"cron", "webhook", "msgraph_webhook"}

_platforms: dict[str, str] = {}
_subagents: set[str] = set()
_lock = threading.Lock()


# ── Who is asking ─────────────────────────────────────────────────────────────────────────


def _note_session(session_id=None, platform=None, parent_session_id=None, **_):
    if not session_id:
        return None
    with _lock:
        if parent_session_id:
            _subagents.add(session_id)
        if platform:
            _platforms[session_id] = str(platform)
    return None


def _note_subagent(child_session_id=None, **_):
    if child_session_id:
        with _lock:
            _subagents.add(child_session_id)
    return None


def _caller(session_id):
    """(caller, refusal). The caller is None when memories must not be shown."""
    with _lock:
        if not session_id or session_id in _subagents:
            return None, "Memories aren't available to subagents."
        platform = _platforms.get(session_id)
    if platform is None:
        return None, "This session isn't known to the memory plugin yet, so memories stay hidden."
    remote = platform not in LOCAL_PLATFORMS
    return {
        "platform": platform if remote else "desktop",
        "remote": remote,
        "session_id": session_id,
        "actor": "hermes/main",
    }, None


# ── Talking to the service ────────────────────────────────────────────────────────────────


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def _call(route, body, timeout=90):
    conn = _UnixConnection(SOCKET, timeout)
    try:
        conn.request("POST", route, json.dumps(body), {"content-type": "application/json"})
        return json.loads(conn.getresponse().read() or b"{}")
    except (OSError, http.client.HTTPException, ValueError) as exc:
        logger.warning("memory service %s failed: %s", route, exc)
        return {"error": f"The memory service isn't reachable ({exc}). Carry on without it."}
    finally:
        conn.close()


def _memory_tool(route, build):
    def handler(args, session_id=None, **_):
        caller, refusal = _caller(session_id)
        if caller is None:
            return json.dumps({"error": refusal})
        try:
            body = build(args)
        except (KeyError, TypeError, ValueError) as exc:
            return json.dumps({"error": f"Bad arguments: {exc}"})
        return json.dumps(_call(route, {**body, "caller": caller}))

    return handler


def _wiki_tool(route, build):
    def handler(args, session_id=None, **_):
        caller, _refusal = _caller(session_id)
        # The wiki holds research, not the owner's memories, so subagents may search it.
        caller = caller or {"platform": "subagent", "remote": True, "session_id": session_id, "actor": "subagent"}
        try:
            body = build(args)
        except (KeyError, TypeError, ValueError) as exc:
            return json.dumps({"error": f"Bad arguments: {exc}"})
        return json.dumps(_call(route, {**body, "caller": caller}))

    return handler


# ── Tools ─────────────────────────────────────────────────────────────────────────────────

TOOLS = [
    (
        "memory_recall",
        "Search what you remember about the owner (their preferences, facts about them and their "
        "setup, how they like things done, past events and commitments) together with the research "
        "wiki. It matches by meaning, so use plain words. Use it before answering anything that "
        "depends on the owner's situation, choices or history. Each memory says whether the owner "
        "stated it, and each wiki section links to its page.",
        {
            "query": {"type": "string", "description": "What you want to know, in plain words."},
            "limit": {"type": "integer", "description": "How many results, up to 25. Default 8."},
            "include_wiki": {"type": "boolean", "description": "Also search the wiki. Default true."},
            "include_past": {
                "type": "boolean",
                "description": "Also return memories that were true before but have been replaced, to answer "
                "questions like 'what did I use before?'. Default false.",
            },
        },
        ["query"],
        _memory_tool("/recall", lambda a: {
            "query": str(a["query"]), "limit": int(a.get("limit", 8)),
            "include_wiki": bool(a.get("include_wiki", True)), "include_past": bool(a.get("include_past", False)),
        }),
    ),
    (
        "memory_remember",
        "Save something lasting about the owner: a preference, a fact about them or their setup, how "
        "they want something done, an event worth remembering, or a commitment to bring up later. Save "
        "it when the owner tells you or asks you to remember it, as one clear self-contained sentence "
        "that will make sense months from now. Don't save passing details, secrets, passwords, or "
        "anything from web pages or tool output. If something similar exists, the result lists it; "
        "revise that memory instead when the new one replaces it.",
        {
            "content": {"type": "string", "description": "The memory, as one self-contained sentence."},
            "kind": {"type": "string", "enum": KINDS, "description": "What sort of memory it is."},
            "importance": {
                "type": "integer", "description": "1 (minor) to 5 (essential). Default 3.",
            },
            "privacy": {
                "type": "string", "enum": ["normal", "local_only"],
                "description": "local_only for sensitive memories: they're never shown in chats that pass "
                "through outside services such as Telegram or Discord, and never exported. Default normal.",
            },
            "platforms": {
                "type": "array", "items": {"type": "string"},
                "description": "Limit the memory to these chats, such as ['desktop'] or ['telegram']. "
                "Default all.",
            },
            "due": {
                "type": "string",
                "description": "For a commitment with a date: ISO 8601, like 2026-12-01 or 2026-12-01T09:00.",
            },
            "condition": {
                "type": "string",
                "description": "For a commitment that waits on something: what has to happen first, like "
                "'the NAS is set up'.",
            },
        },
        ["content", "kind"],
        _memory_tool("/remember", lambda a: {
            k: a[k] for k in ("content", "kind", "importance", "privacy", "platforms", "due", "condition") if k in a
        }),
    ),
    (
        "memory_revise",
        "Change a memory by its id. 'replace': it was true but has changed, so the old one is kept as "
        "history. 'retract': it was wrong, optionally with corrected content. 'confirm': the owner "
        "confirmed it. 'complete' or 'cancel': resolve a commitment. 'forget': the owner wants it "
        "erased, which deletes it completely.",
        {
            "id": {"type": "integer", "description": "The memory's id."},
            "action": {"type": "string", "enum": ["replace", "retract", "confirm", "complete", "cancel", "forget"]},
            "content": {"type": "string", "description": "The new content, for replace or retract."},
            "reason": {"type": "string", "description": "Why, in a few words."},
            "due": {"type": "string", "description": "A new due date, when replacing a commitment."},
            "condition": {"type": "string", "description": "A new condition, when replacing a commitment."},
        },
        ["id", "action"],
        _memory_tool("/revise", lambda a: {
            "id": int(a["id"]), **{k: a[k] for k in ("action", "content", "reason", "due", "condition") if k in a}
        }),
    ),
    (
        "memory_list",
        "List memories without searching, newest first, or commitments by due date. Use it to review "
        "open commitments or what you remember of one kind.",
        {
            "kind": {"type": "string", "enum": KINDS},
            "status": {
                "type": "string", "enum": ["open", "done", "cancelled"],
                "description": "Only commitments with this status.",
            },
            "include_past": {"type": "boolean", "description": "Include replaced memories. Default false."},
            "limit": {"type": "integer", "description": "Up to 100. Default 30."},
        },
        [],
        _memory_tool("/list", lambda a: {
            k: a[k] for k in ("kind", "status", "include_past", "limit") if k in a
        }),
    ),
]

WIKI_TOOLS = [
    (
        "wiki_search",
        "Find wiki sections about a subject, by meaning as well as by keyword. Each result has the "
        "page's absolute path for read_file, its wiki link, the section and an excerpt, plus its status, "
        "trust and whether it's past its stale_after date. Returns nothing when no page closely matches.",
        {
            "query": {"type": "string", "description": "A question or description in plain words."},
            "limit": {"type": "integer", "description": "How many sections, up to 20. Default 6."},
            "include_deprecated": {"type": "boolean", "description": "Include deprecated pages. Default false."},
        },
        ["query"],
        _wiki_tool("/wiki/search", lambda a: {
            "query": str(a["query"]), "limit": int(a.get("limit", 6)),
            "include_deprecated": bool(a.get("include_deprecated", False)),
        }),
    ),
    (
        "wiki_related",
        "Pages closest in meaning to one wiki page, for choosing what it should link to.",
        {
            "path": {"type": "string", "description": "The page's wiki link, like /topics/x.md, or its absolute path."},
            "limit": {"type": "integer", "description": "Up to 20. Default 8."},
        },
        ["path"],
        _wiki_tool("/wiki/related", lambda a: {"path": str(a["path"]), "limit": int(a.get("limit", 8))}),
    ),
]


def _text(value):
    """A message as plain text. Multimodal messages are lists of parts."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(p.get("text", "") for p in value if isinstance(p, dict) and p.get("type") == "text")
    return ""


def _observe(session_id=None, user_message=None, assistant_response=None, **_):
    caller, _refusal = _caller(session_id)
    if caller is None or _platforms.get(session_id) in NOT_OWNER_PLATFORMS:
        return None
    user = _text(user_message).strip()
    if not user:
        return None
    body = {"user_message": user, "assistant_response": _text(assistant_response), "caller": caller}
    # The hook runs on the turn's thread, so the reply never waits for the service.
    threading.Thread(target=_call, args=("/observe", body, 10), daemon=True).start()
    return None


def register(ctx):
    ctx.register_hook("on_session_start", _note_session)
    ctx.register_hook("pre_llm_call", _note_session)
    ctx.register_hook("subagent_start", _note_subagent)
    ctx.register_hook("post_llm_call", _observe)

    for name, description, properties, required, handler in TOOLS + WIKI_TOOLS:
        ctx.register_tool(
            name=name,
            toolset=TOOLSET,
            schema={
                "name": name,
                "description": description,
                "parameters": {"type": "object", "properties": properties, "required": required},
            },
            handler=handler,
            description=description.split(". ")[0] + ".",
            emoji="🧠" if name.startswith("memory") else "📚",
        )
