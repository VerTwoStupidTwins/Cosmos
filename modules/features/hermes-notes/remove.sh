# Deletes an inbox note the transcriber wrote, together with the drawing it was transcribed from.
# Used for notes the owner marked `review: delete` (by the nightly job's script) and notes Hermes has
# filed into the vault, `review: filed` (by the transcriber). The only thing that deletes notes.
#
# Usage: notes-remove <note>, where the note is in the vault's Inbox folder.

notes=${NOTES:-/var/lib/hermes/notes}
note=$1

if [[ $note != "$notes/Inbox/"*.md || $note == *..* || ! -f $note ]]; then
  echo "notes-remove: $note is not a note in $notes/Inbox, so it was kept" >&2
  exit 1
fi

# The front matter's value for a key, or nothing.
field() {
  awk -v key="$1" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  ' "$note"
}

if [[ -z $(field text-sha256) ]]; then
  echo "notes-remove: $note wasn't written by the transcriber, so it was kept" >&2
  exit 1
fi

# source: "[[Excalidraw/Drawing 2026-11-18 15.17.25.excalidraw]]" names the drawing's two files,
# Drawing ….excalidraw.md and Drawing ….excalidraw.png.
source=$(field source)
source=${source#\"[[}
source=${source%]]\"}
if [[ $source == *.excalidraw && $source != *..* && $source != /* ]]; then
  rm -f -- "$notes/$source.md" "$notes/$source.png"
  echo "removed ${note#"$notes"/} and its drawing $source"
else
  echo "removed ${note#"$notes"/} (its source, $source, isn't a drawing, so nothing else was)"
fi
rm -f -- "$note"
