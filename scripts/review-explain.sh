#!/usr/bin/env bash
# Seed the notes the agent leaves on its own changes before a --local review
# (UX-12, COMMIT-23): the why a reader would stop to ask, on the line it is
# about, gone when the review closes. review-diff.sh --explain preloads them
# where the tool can show them; a note returned as seeded, or deleted, was read,
# and only an edited or a new note is the reviewer answering.
#
# The skill decides what each note says and where it goes
# (guides/review-notes.md); this script holds each one to a line the review
# shows, anchors it where revdiff draws it, and writes the files the review
# reads.
#
# Usage:
#   review-explain.sh --notes <notes.json> [--path <p>...] [--repo <path>]
#
# The notes file, written by the skill:
#   {"notes": [{"file": "<path>", "line": <n>, "side": "new|old", "note": "<text>"},
#              {"file": "<path>", "note": "<text>"}]}
# A line is numbered in the working tree as it stands, or in HEAD for a removed
# line (side old); a note with no line is about the whole file. The --path list
# is the one the review will be given: the notes are anchored in what it shows.
#
# Output is KEY=value lines:
#   EXPLAIN_NOTES=<path>  the notes in revdiff's markdown, for --explain; the
#                         anchored JSON the review reads back sits beside it
#   NOTE_COUNT=<n>
# Every note that can't be placed prints its own EXPLAIN_ERROR=<message>, and
# the script exits 65 having written nothing.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/stage-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-paths.sh"
# shellcheck source=lib/item-review.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/item-review.sh"

CTX_REPO="" notes=""
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --notes) notes="${2:?--notes needs a file}"; shift 2 ;;
    --path)  paths+=("${2:?--path needs a path}"); shift 2 ;;
    *) echo "review-explain.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$notes" && -r "$notes" ]] || { echo "review-explain.sh: --notes needs a readable file" >&2; exit 64; }
jq -e '.notes | type == "array"' "$notes" >/dev/null 2>&1 \
  || { echo "review-explain.sh: --notes needs {\"notes\": [...]}: $notes" >&2; exit 65; }
ctx_resolve_repo
anchor_reject_absolute review-explain.sh "${paths[@]+"${paths[@]}"}" || exit $?
root=$(git rev-parse --show-toplevel)

in_scope() {
  local f="$1" p
  [[ ${#paths[@]} -gt 0 ]] || return 0
  for p in "${paths[@]}"; do
    p="${p%/}"
    [[ "$f" == "$p" || "$f" == "$p"/* ]] && return 0
  done
  return 1
}

dir=$(anchor_tmpdir anchor-review-explain)
now=$(anchor_review_snapshot "${paths[@]+"${paths[@]}"}")
specs=()
for p in "${paths[@]+"${paths[@]}"}"; do specs+=(":/$p"); done
lines="$dir/changed.tsv"
anchor_items_changed_lines "$root" "$(anchor_local_base)" "$now" "${specs[@]+"${specs[@]}"}" > "$lines"

errors=()
anchors="$dir/anchors.tsv"; : > "$anchors"
# A unit separator, not a tab: tabs are IFS whitespace, so an empty line field
# would collapse into the next one.
while IFS=$'\x1f' read -r k file line side text; do
  [[ -n "$k" ]] || continue
  where="$file${line:+:$line}"
  if [[ -z "$file" || -z "$text" ]]; then
    errors+=("note $((k + 1)) needs a file and a note"); continue
  fi
  if [[ -n "$line" && ! "$line" =~ ^[0-9]+$ ]] || [[ "$side" != new && "$side" != old ]]; then
    errors+=("$where: a line is a number and a side is new or old"); continue
  fi
  if ! in_scope "$file"; then
    errors+=("$where: not in this review's paths"); continue
  fi
  if ! cut -f1 "$lines" | grep -xF -- "$file" >/dev/null; then
    errors+=("$where: not changed in this review, so the note has nowhere to sit"); continue
  fi
  if [[ -z "$line" ]]; then
    printf '%s\tfile\t\n' "$k" >> "$anchors"; continue
  fi
  if ! at=$(anchor_items_anchor "$lines" "$root" "$now" "$file" "$line" "$side"); then
    errors+=("$where: $at"); continue
  fi
  printf '%s\t%s\n' "$k" "$at" >> "$anchors"
done < <(jq -r '.notes | to_entries[]
  | [.key, (.value.file // ""), (.value.line // ""), (.value.side // "new"), (.value.note // "" | gsub("^\\s+|\\s+$"; ""))]
  | map(tostring) | join("\u001f")' "$notes")

jq --rawfile a "$anchors" '
  ($a | split("\n") | map(select(length > 0) | split("\t") | {k:(.[0]|tonumber), marker:.[1], line:(if .[2] == "" then null else (.[2]|tonumber) end)})) as $anchors
  | [.notes | to_entries[] | .key as $k | .value as $n
     | ($anchors[] | select(.k == $k)) as $s
     | {file:$n.file, line:$s.line, marker:$s.marker,
        side:(if $s.marker == "-" then "old" else "new" end),
        body:($n.note | gsub("^\\s+|\\s+$"; ""))}]' "$notes" > "$dir/notes.json"
anchor_items_onto_hunks "$dir/notes.json" "$lines"
while IFS= read -r far; do
  errors+=("$far: not near a change; a note explains a change, so it goes on or beside one")
done < <(jq -r '.[] | select(.far) | "\(.file):\(.line + 1)"' "$dir/notes.json")
if [[ ${#errors[@]} -gt 0 ]]; then
  for e in "${errors[@]}"; do echo "EXPLAIN_ERROR=$e"; done
  rm -rf "$dir"
  exit 65
fi

anchor_items_notes_md "$dir/notes.json" > "$dir/notes.md"
rm -f "$lines" "$anchors"
echo "EXPLAIN_NOTES=$dir/notes.md"
echo "NOTE_COUNT=$(jq length "$dir/notes.json")"
