# Script for Hermes' nightly notes-ingest job, run before the agent; what it prints goes into the
# agent's prompt. It deletes the inbox notes the owner marked `review: delete` (with their drawings),
# then lists the ones marked `review: accept` for Hermes to file. Notes still `pending` wait.
inbox=${NOTES:-/var/lib/hermes/notes}/Inbox
accepted=()
deleted=()
shopt -s nullglob
for note in "$inbox"/*.md; do
  review=$(@awk@ 'NR == 1 && $0 != "---" { exit }
                  NR > 1 && $0 == "---" { exit }
                  NR > 1 && index($0, "review: ") == 1 { print substr($0, 9); exit }' "$note")
  case $review in
    delete) @remove@ "$note" && deleted+=("${note##*/}") ;;
    accept) accepted+=("$note") ;;
  esac
done

echo "Inbox notes deleted at the owner's request: ${#deleted[@]}"
if ((${#deleted[@]})); then printf -- '- %s\n' "${deleted[@]}"; fi
echo
echo "Accepted inbox notes to ingest with the notes-ingest skill: ${#accepted[@]}"
if ((${#accepted[@]})); then printf -- '- %s\n' "${accepted[@]}"; fi
