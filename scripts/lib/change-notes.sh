# shellcheck shell=bash
# The notes the agent leaves on its own changes in a --local review (UX-12,
# COMMIT-23): the why a reader would stop to ask, on the line it is about, gone
# when the review closes. review-diff.sh --notes places them here, then preloads
# them where the tool can show them; a note returned as placed, or deleted, was
# read, and only an edited or a new note is the reviewer answering.
#
# The skill decides what each note says and where it goes
# (guides/review-notes.md); this holds each one to a line the review shows and
# anchors it where revdiff draws it.
#
# The notes file, written by the skill:
#   {"notes": [{"file": "<path>", "line": <n>, "side": "new|old", "note": "<text>"},
#              {"file": "<path>", "note": "<text>"}]}
# A line is numbered in the working tree as it stands, or in HEAD for a removed
# line (side old); a note with no line is about the whole file.
#
# Sourced only, from the repo's root; the caller sources lib/tmpfile.sh,
# lib/stage-paths.sh, and lib/item-review.sh first.

# anchor_change_notes_place <notes.json> [<path>...]
# Places the notes in what a review of <path>s shows and prints the markdown
# revdiff preloads; the anchored JSON the review reads back sits beside it. Every
# note that can't be placed prints its own NOTES_ERROR=<message>, and it returns
# 65 having written nothing.
anchor_change_notes_place() {
  local in="$1" root dir now lines anchors k file line side text where at p e
  local -a specs=() errors=()
  shift
  jq -e '.notes | type == "array"' "$in" >/dev/null 2>&1 \
    || { echo "NOTES_ERROR=--notes needs {\"notes\": [...]}: $in"; return 65; }
  root=$(git rev-parse --show-toplevel)
  dir=$(anchor_tmpdir anchor-change-notes)
  now=$(anchor_review_snapshot "$@")
  for p in "$@"; do specs+=(":/$p"); done
  lines="$dir/changed.tsv"
  anchor_items_changed_lines "$root" "$(anchor_local_base)" "$now" "${specs[@]+"${specs[@]}"}" > "$lines"

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
    if ! anchor_items_in_scope "$file" "$@"; then
      errors+=("$where: not in this review's paths"); continue
    fi
    if ! anchor_items_file_changed "$lines" "$file"; then
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
    | map(tostring) | join("\u001f")' "$in")

  jq --rawfile a "$anchors" '
    ($a | split("\n") | map(select(length > 0) | split("\t") | {k:(.[0]|tonumber), marker:.[1], line:(if .[2] == "" then null else (.[2]|tonumber) end)})) as $anchors
    | [.notes | to_entries[] | .key as $k | .value as $n
       | ($anchors[] | select(.k == $k)) as $s
       | {file:$n.file, line:$s.line, marker:$s.marker,
          side:(if $s.marker == "-" then "old" else "new" end),
          body:($n.note | gsub("^\\s+|\\s+$"; ""))}]' "$in" > "$dir/notes.json"
  # A note on an unchanged line explains the change it sits beside, so one more
  # than this many lines from every change in its file is refused.
  local near=3 far
  while IFS= read -r far; do
    errors+=("$far: not near a change; a note explains a change, so it goes on or beside one")
  done < <(jq -r --rawfile l "$lines" --argjson near "$near" '
    ($l | split("\n") | map(select(length > 0) | split("\t") | {file:.[0], side:.[1], line:(.[2] | tonumber)})) as $rows
    | def changes($f): [$rows[] | select(.file == $f)] | (map(select(.side == "+")) as $p | if ($p | length) > 0 then $p else . end);
    .[] | select(.marker == " ") | . as $n
    | (changes($n.file) | map((.line - $n.line) | fabs) | min) as $d
    | select($d == null or $d > $near) | "\(.file):\(.line + 1)"' "$dir/notes.json")
  if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo "NOTES_ERROR=$e"; done
    rm -rf "$dir"
    return 65
  fi

  anchor_items_notes_md "$dir/notes.json" > "$dir/notes.md"
  rm -f "$lines" "$anchors"
  printf '%s\n' "$dir/notes.md"
}
