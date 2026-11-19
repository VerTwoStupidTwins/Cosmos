# Transcribes handwritten Excalidraw drawings in the Notes vault into Markdown notes.
#
# Every Drawing X.excalidraw.png (the PNG Excalidraw exports beside each drawing) gets a note,
# Inbox/Drawing X.md: the model's transcription, then the drawing embedded for checking. The owner
# files or deletes notes from the inbox; the service finds a note wherever it went by its `source:`
# link, and remembers every PNG it has transcribed, so:
# - an unchanged PNG is never sent again, and a deleted note stays deleted;
# - a changed PNG updates its note where it is, unless the note was edited since (by the owner or
#   Hermes): then the edits stay and the note is marked `transcription: outdated` instead;
# - a changed PNG whose note was deleted gets a new note in the inbox.
#
# Environment: NOTES (the vault), STATE (a folder of the service's own), API (an OpenAI-style chat
# completions URL), MODEL, and the system prompt and request text as files, PROMPT and REQUEST.

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

log() { printf '%s\n' "$*" >&2; }

# The front matter's value for a key, or nothing.
field() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  ' "$1"
}

# Everything after the front matter.
body() {
  awk 'c < 2 && $0 == "---" { c++; next } c >= 2' "$1"
}

seen="$STATE/transcribed"
touch "$seen"

# The note whose source is this drawing, wherever it is in the vault, or nothing.
find_note() {
  grep -rlF --include='*.md' --exclude='.*' --exclude-dir='.*' -- "source: \"[[$1]]\"" "$NOTES" | head -n 1 || true
}

transcribe() {
  local png=$1
  [[ $png == *.excalidraw.png ]] || return 0
  [[ -f $png ]] || return 0

  local name link note png_hash
  name=$(basename "$png" .excalidraw.png)
  # The drawing by its path in the vault, so drawings with the same name in different folders stay
  # apart. Obsidian updates these links when the drawing moves.
  link=${png#"$NOTES"/}
  link=${link%.png}
  png_hash=$(sha256sum "$png" | cut -d' ' -f1)
  note=$(find_note "$link")

  if [[ -n $note ]]; then
    if [[ -z $(field "$note" text-sha256) ]]; then
      log "$note: not one of this service's notes, left alone"
      return 0
    fi
    [[ $(field "$note" png-sha256) == "$png_hash" ]] && return 0
    if [[ $(body "$note" | sha256sum | cut -d' ' -f1) != "$(field "$note" text-sha256)" ]]; then
      if [[ $(field "$note" transcription) != outdated ]]; then
        sed -i '0,/^transcription: .*/s//transcription: outdated/' "$note"
        log "$note: edited since it was written, so marked outdated instead of replaced"
      fi
      return 0
    fi
  else
    # Transcribed before, and the note deleted since.
    grep -qxF "$png_hash" "$seen" && return 0
    mkdir -p "$NOTES/Inbox"
    note="$NOTES/Inbox/$name.md"
    local n=2
    while [[ -e $note ]]; do
      note="$NOTES/Inbox/$name $n.md"
      n=$((n + 1))
    done
  fi

  log "transcribing $png"
  base64 -w0 "$png" > "$work/image"
  # The rules go in the system prompt and again, shorter, in the request itself: this model follows
  # the request's more closely. Thinking is off: with it on, the whole transcription sometimes
  # arrives as "reasoning" with an empty reply.
  jq -n --arg model "$MODEL" --rawfile prompt "$PROMPT" --rawfile request "$REQUEST" --rawfile image "$work/image" '{
    model: $model,
    temperature: 0,
    chat_template_kwargs: { enable_thinking: false },
    messages: [
      { role: "system", content: $prompt },
      { role: "user", content: [
        { type: "image_url", image_url: { url: ("data:image/png;base64," + $image) } },
        { type: "text", text: $request }
      ] }
    ]
  }' > "$work/request"

  if ! curl -sf -m 300 -H 'Content-Type: application/json' -d @"$work/request" "$API" > "$work/response"; then
    log "$png: the model didn't answer; it will be tried again when the PNG next changes or the service restarts"
    return 0
  fi

  local text
  # The reply, or the reasoning if the reply came back empty anyway. Code fences, if the model adds
  # them, would hide the Markdown in Obsidian; a bare [sketch: …] line gets its italics.
  text=$(jq -r '(.choices[0].message.content // "") as $c
    | if ($c | test("\\S")) then $c else (.choices[0].message.reasoning_content // "") end' "$work/response" \
    | sed -e '/^```/d' -e 's/^\[\(sketch:.*\|no writing\)\]$/_[\1]_/')
  if [[ -z ${text//[[:space:]]/} ]]; then
    log "$png: empty transcription, skipped"
    return 0
  fi

  printf '%s\n\n![[%s]]\n' "$text" "$link" > "$work/body"
  {
    printf -- '---\n'
    printf 'source: "[[%s]]"\n' "$link"
    printf 'tags: [handwritten]\n'
    printf 'transcribed: %s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf 'transcription: current\n'
    printf 'png-sha256: %s\n' "$png_hash"
    printf 'text-sha256: %s\n' "$(sha256sum < "$work/body" | cut -d' ' -f1)"
    printf -- '---\n'
    cat "$work/body"
  } > "$work/note"
  # Into place in one step, so the sync never uploads half a note.
  local dir
  dir=$(dirname "$note")
  cp "$work/note" "$dir/.$name.md.tmp"
  mv "$dir/.$name.md.tmp" "$note"
  echo "$png_hash" >> "$seen"
  log "wrote $note"
}

# Watch first, so nothing exported during the start-up pass is missed.
inotifywait -m -r -q -e close_write -e moved_to --exclude '/\.' --format '%w%f' "$NOTES" > "$work/events" &
watcher=$!

while IFS= read -r -d '' png; do
  transcribe "$png"
done < <(find "$NOTES" -path '*/.*' -prune -o -name '*.excalidraw.png' -print0)

# The sync writes a file and may touch it again straight after; give it a moment to settle.
tail -n +1 -f --pid="$watcher" "$work/events" | while IFS= read -r path; do
  [[ $path == *.excalidraw.png ]] || continue
  sleep 2
  transcribe "$path"
done
