#!/usr/bin/env bash
# .forgejo/scripts/flake-update.sh
# The weekly update (.forgejo/workflows/update.yml): updates flake.lock, builds every host before and after, and lists
# what changes on each (nvd). If anything does, it pushes the new lock to the update/flake-lock branch, opens or
# refreshes a pull request with the full lists, and sends a summary through ntfy. Everything it builds is in the
# binary cache by then, so merging and rebuilding mostly downloads. A failed build is reported through ntfy too.
#
# Needs: TOKEN (the job's Forgejo token) and the GITHUB_* variables Forgejo Actions sets; lugh's runner provides the
# ntfy token as a credential (modules/features/forgejo.nix).
set -euo pipefail

branch=update/flake-lock
api="$GITHUB_SERVER_URL/api/v1/repos/$GITHUB_REPOSITORY"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_NUMBER"
ntfy_token=/run/credentials/forgejo-runner-lugh.service/ntfy-token
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

notify() { # title, message, click URL, tags
	[ -r "$ntfy_token" ] || { echo "no ntfy token; not notifying"; return 0; }
	curl -fsS -o /dev/null -H "authorization: Bearer $(<"$ntfy_token")" \
		-H "title: $1" -H "click: $3" -H "tags: $4" --data-binary "$2" http://127.0.0.1:2586/homelab || true
}
trap 'notify "Weekly update failed" "The update job stopped; see the log." "$run_url" "warning"' ERR

forgejo() { curl -fsS -H "authorization: token $TOKEN" -H 'content-type: application/json' "$@"; }
# Before any building: the pull request step needs the token, and an empty one only shows as a 404 at the end.
if [ -z "${TOKEN:-}" ] || ! forgejo -o /dev/null "$api"; then
	echo "The job's Forgejo token is missing or can't read $GITHUB_REPOSITORY; stopping before building." >&2
	false
fi
toplevel() { nix build --no-link --print-out-paths ".#nixosConfigurations.$1.config.system.build.toplevel"; }

hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]')

echo "::group::Building the current lock"
declare -A before after
for host in $hosts; do before[$host]=$(toplevel "$host"); done
echo "::endgroup::"

# Without a token GitHub allows 60 API requests an hour per address, and Nix then quietly keeps the old revisions.
github_token=/run/credentials/forgejo-runner-lugh.service/github-token
if [ -r "$github_token" ]; then
	NIX_CONFIG="access-tokens = github.com=$(<"$github_token")${NIX_CONFIG:+$'\n'$NIX_CONFIG}" nix flake update 2>"$work/inputs"
else
	nix flake update 2>"$work/inputs"
fi
cat "$work/inputs"
if grep -q "using cached version" "$work/inputs"; then
	echo "Some inputs couldn't be checked (see above), so this update would be incomplete; stopping." >&2
	false
fi
if git diff --quiet flake.lock; then
	echo "No input has moved; nothing to do."
	exit 0
fi

echo "::group::Building the updated lock"
for host in $hosts; do after[$host]=$(toplevel "$host"); done
echo "::endgroup::"

# Keep the updated builds from lugh's garbage collection until the pull request is merged (main's CI run keeps them
# after that), replacing last week's.
mkdir -p "$HOME/gcroots"
for host in $hosts; do nix-store --add-root "$HOME/gcroots/update-$host" --realise "${after[$host]}" >/dev/null; done

# Per host: the nvd report, and a count of version changes.
summary=()
details=""
headline=()
for host in $hosts; do
	[ "${before[$host]}" = "${after[$host]}" ] && continue
	nix run nixpkgs#nvd -- diff "${before[$host]}" "${after[$host]}" >"$work/$host" || true
	updates=$(grep -cE '^\[U' "$work/$host" || true)
	added=$(grep -cE '^\[A' "$work/$host" || true)
	removed=$(grep -cE '^\[R' "$work/$host" || true)
	line="$host $updates updates"
	[ "$added" -gt 0 ] && line+=", $added added"
	[ "$removed" -gt 0 ] && line+=", $removed removed"
	summary+=("$line")
	# Packages the host names directly ([U*]) make the headline.
	while read -r name version; do headline+=("$name $version"); done < <(
		awk '/^\[U\*\]/ { print $3, $NF }' "$work/$host"
	)
	details+=$'\n'"<details><summary><b>$line</b></summary>"$'\n\n```\n'"$(cat "$work/$host")"$'\n```\n</details>\n'
done

if [ ${#summary[@]} -eq 0 ]; then
	echo "The lock moved, but no host's system changes; nothing to review."
	exit 0
fi

# The new lock on the update branch (replacing last week's if it wasn't merged).
date=$(date +%F)
git config user.name "Cosmos CI"
git config user.email "ci@git.gatica.one"
git checkout -B "$branch"
git commit -q -m "Update flake inputs ($date)" -m "$(sed -n 's/^• //p' "$work/inputs")" flake.lock
git push -fq origin "$branch"

title="Update flake inputs ($date)"
body="Built on lugh: everything below is already in the binary cache, so merging and rebuilding mostly downloads.

**$(
	IFS=$'\n'
	echo "${summary[*]}"
)**

### Inputs
\`\`\`
$(sed -n 's/^• //p' "$work/inputs")
\`\`\`

### What changes on each host
$details"

existing=$(forgejo "$api/pulls?state=open&limit=50" | jq -r --arg b "$branch" '.[] | select(.head.ref == $b) | .number' | head -1)
payload=$(jq -n --arg t "$title" --arg b "$body" --arg h "$branch" '{title: $t, body: $b, head: $h, base: "main"}')
if [ -n "$existing" ]; then
	pr=$(forgejo -X PATCH "$api/pulls/$existing" -d "$payload" | jq -r .html_url)
else
	pr=$(forgejo -X POST "$api/pulls" -d "$payload" | jq -r .html_url)
fi
echo "Pull request: $pr"

message=$(
	IFS=$'\n'
	echo "${summary[*]}"
)
if [ ${#headline[@]} -gt 0 ]; then
	message+=$'\n\n'"$(printf '%s\n' "${headline[@]}" | sort -u | head -8)"
fi
notify "Updates ready to review" "$message" "$pr" "package"
