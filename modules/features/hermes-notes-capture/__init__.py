"""Saves the owner's notes from chat into the Notes vault's inbox.

Voice messages reach the agent only as Whisper's transcript, and the gateway clears its audio cache
on its own schedule. So a pre_transcription hook keeps a copy of every recording for a day, and
note_capture moves the newest one, if it arrived in the last few minutes, into the vault beside the
note. On this single-owner system the newest recording is the voice message being saved.

The inbox note has the same front matter as the transcriber's handwritten ones, so the owner reviews
it the same way (`review: accept` or `delete`), and the nightly notes-ingest job files or deletes it.
notes-remove deletes the recording with the note.
"""

import hashlib
import json
import logging
import os
import shutil
import time
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

VAULT = Path("/var/lib/hermes/notes")
# Outside the vault, so held recordings never sync.
HOLD = Path("/var/lib/hermes/voice-hold")
HOLD_FOR = 24 * 3600
# A recording older than this is not the voice message being saved.
RECENT = 10 * 60
AUDIO = {".ogg", ".oga", ".opus", ".mp3", ".m4a", ".wav", ".aac", ".webm", ".flac"}

SCHEMA = {
    "name": "note_capture",
    "description": (
        "Save a note from the owner into their private Notes vault's inbox, for them to review. Use it "
        "for every message in the Telegram Notes topic, and anywhere for a message that starts with "
        "'note:' or 'take a note'. Pass the note text after the light cleanup the notes-ingest skill "
        "describes. For a voice message, set voice to true, and the recording is kept beside the note. "
        "Never use it for the research wiki."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": "The note in Markdown: the owner's words, lightly cleaned up, with spoken or written to-dos as '- [ ] ' lines.",
            },
            "voice": {
                "type": "boolean",
                "description": "True when the note came from a voice message, so its recording is kept with it.",
                "default": False,
            },
        },
        "required": ["text"],
    },
}


def _error(message):
    return json.dumps({"success": False, "error": message})


def _hold(file_path=None, **_):
    """pre_transcription hook: copy the recording before the gateway clears its cache."""
    try:
        if not file_path:
            return None
        src = Path(file_path)
        if src.suffix.lower() not in AUDIO or not src.is_file():
            return None
        HOLD.mkdir(parents=True, exist_ok=True)
        now = time.time()
        for old in HOLD.iterdir():
            if now - old.stat().st_mtime > HOLD_FOR:
                old.unlink(missing_ok=True)
        # A plain copy, so the file's time is when it arrived.
        shutil.copy(src, HOLD / f"{time.time_ns()}{src.suffix.lower()}")
    except Exception:
        logger.exception("notes-capture: couldn't keep a copy of %s", file_path)
    # Nothing to change about the transcription itself.
    return None


def _newest_recording():
    if not HOLD.is_dir():
        return None
    held = [p for p in HOLD.iterdir() if p.suffix in AUDIO]
    if not held:
        return None
    newest = max(held, key=lambda p: p.stat().st_mtime)
    return newest if time.time() - newest.stat().st_mtime <= RECENT else None


def _free(path):
    """path, or path with " 2", " 3"… before the extension, whichever doesn't exist yet."""
    candidate, n = path, 2
    while candidate.exists():
        candidate = path.with_name(f"{path.stem} {n}{path.suffix}")
        n += 1
    return candidate


def _capture(args):
    text = str(args.get("text") or "").strip()
    if not text:
        return _error("The note is empty.")
    voice = bool(args.get("voice"))

    now = datetime.now()
    kind = "Voice" if voice else "Note"
    note = _free(VAULT / "Inbox" / f"{kind} {now:%Y-%m-%d %H.%M.%S}.md")
    note.parent.mkdir(parents=True, exist_ok=True)

    recording = _newest_recording() if voice else None
    if recording is not None:
        audio = _free(VAULT / "Voice" / f"{note.stem}{recording.suffix}")
        audio.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(recording, audio)
        link = audio.relative_to(VAULT).as_posix()
        body = f"{text}\n\n![[{link}]]\n"
        source = f'"[[{link}]]"'
    else:
        body = f"{text}\n"
        source = "voice" if voice else "chat"

    front = "\n".join(
        [
            "---",
            f"source: {source}",
            f"tags: [{'voice' if voice else 'typed'}]",
            f"captured: {now:%Y-%m-%d %H:%M}",
            "review: pending",
            # notes-remove deletes only inbox notes carrying this, like the transcriber's.
            f"text-sha256: {hashlib.sha256(body.encode()).hexdigest()}",
            "---",
            "",
        ]
    )
    tmp = note.with_name(f".{note.name}.tmp")
    tmp.write_text(front + body)
    os.replace(tmp, note)

    result = {"success": True, "note": note.relative_to(VAULT).as_posix()}
    if voice:
        result["recording"] = "kept" if recording is not None else "not found (transcript only)"
    return json.dumps(result)


def register(ctx):
    def handler(args, **kwargs):
        try:
            return _capture(args)
        except Exception as exc:
            logger.exception("note_capture failed")
            return _error(f"Unexpected error: {exc}")

    ctx.register_hook("pre_transcription", _hold)
    # The file toolset, so it's available wherever the agent can write files.
    ctx.register_tool(
        name="note_capture",
        toolset="file",
        schema=SCHEMA,
        handler=handler,
        description="Save a note to the owner's Notes inbox.",
        emoji="📝",
    )
