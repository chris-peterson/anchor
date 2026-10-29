#!/usr/bin/env bash
# The Review status section of a CR description: each commit on the CR, how many
# review rounds it has been in, who reviewed it, and the result of the latest one. A review of a
# range gives every commit in it another round, so a commit reviewed on its own
# and again as part of the whole change counts both.
#
# A commit is keyed by its patch-id, not its sha: a rebase that leaves its change
# as it was keeps its rounds, and an amend that changes it starts again at none.
# The keys live in a comment the forge doesn't render, on the line that opens
# the section; the table below it is what a reader sees.
#
# Sourced only. Every function reads the repo in the current directory.
#
#   review_status_data <description file>
#                         the recorded rounds as {"<key>": {rounds, by, result}};
#                         {} for a description without the section
#   review_status_rows <data json> <base> <head>
#                         the commits in <base>..<head>, oldest first, as
#                         [{sha, key, rounds, by, result}], 0 rounds where
#                         unrecorded
#   review_status_add <data json> <base> <head> <result> <reviewer>
#                         the data with every commit in <base>..<head> given
#                         another round by <reviewer> whose result is <result>
#   review_status_section <data json> <rows json>
#                         the section, opening comment through closing comment
#   review_status_splice <description file> <section file>
#                         the description with its section replaced by the new
#                         one, or the new one appended where it had none
#   review_status_strip <description file> <section file>
#                         the description without its section, which goes to
#                         <section file>; that file is empty where it had none

REVIEW_STATUS_MARK="anchor:review-status"

# One "<sha> <key>" line per commit, oldest first. A commit with no diff has no
# patch-id, so its sha is its key.
review_status_keys() {
  local sha key
  git rev-list --reverse --no-merges "$1..$2" | while read -r sha; do
    key=$(git show --format= "$sha" | git patch-id --stable | cut -d' ' -f1)
    printf '%s %s\n' "$sha" "${key:-$sha}"
  done
}

review_status_data() {
  local line
  line=$(grep -o "<!-- $REVIEW_STATUS_MARK {.*} -->" "$1" | head -n 1 || true)
  if [[ -z "$line" ]]; then
    echo '{}'
    return
  fi
  line=${line#"<!-- $REVIEW_STATUS_MARK "}
  jq -c . <<<"${line%" -->"}"
}

review_status_rows() {
  review_status_keys "$2" "$3" | jq -Rnc --argjson d "$1" '
    [inputs | split(" ") | {sha: .[0], key: .[1]}
     | . + {rounds: ($d[.key].rounds // 0), by: ($d[.key].by // []), result: ($d[.key].result // "")}]'
}

review_status_add() {
  review_status_keys "$2" "$3" | jq -Rnc --argjson d "$1" --arg r "$4" --arg w "$5" '
    reduce (inputs | split(" ")[1]) as $k ($d;
      (.[$k].by // []) as $by
      | .[$k] = {rounds: ((.[$k].rounds // 0) + 1),
                 by: (if ($by | index([$w])) then $by else $by + [$w] end),
                 result: $r})'
}

# Commits drop off the table when the CR no longer has them, and their keys stay
# in the data: a commit that comes back unchanged keeps what it had.
review_status_section() {
  printf '<!-- %s %s -->\n' "$REVIEW_STATUS_MARK" "$(jq -c . <<<"$1")"
  printf '## Review status\n\n'
  printf '| Commit | Review rounds | Reviewed by | Latest result |\n| --- | --- | --- | --- |\n'
  # A login goes in bare: an @ in a description notifies the person it names.
  jq -r '.[] | "| \(.sha[0:8]) | \(.rounds) | \(.by | join(", ")) | \(if .rounds == 0 then "not reviewed" else .result end) |"' <<<"$2"
  printf '<!-- /%s -->\n' "$REVIEW_STATUS_MARK"
}

review_status_splice() {
  if grep -q "<!-- $REVIEW_STATUS_MARK " "$1"; then
    awk -v open="<!-- $REVIEW_STATUS_MARK " -v end="<!-- /$REVIEW_STATUS_MARK -->" -v section="$2" '
      index($0, open) == 1 { while ((getline line < section) > 0) print line; skip = 1; next }
      skip && $0 == end  { skip = 0; next }
      !skip' "$1"
  elif grep -q '[^[:space:]]' "$1"; then
    cat "$1"
    [[ -z "$(tail -c 1 "$1")" ]] || printf '\n'
    printf '\n'
    cat "$2"
  else
    cat "$2"
  fi
}

# Blank lines are held until the next line with text, so the ones that led up
# to the section don't trail what is left.
review_status_strip() {
  : > "$2"
  awk -v open="<!-- $REVIEW_STATUS_MARK " -v end="<!-- /$REVIEW_STATUS_MARK -->" -v out="$2" '
    index($0, open) == 1 { on = 1 }
    on { print > out; if ($0 == end) on = 0; next }
    /^[[:space:]]*$/ { held = held $0 "\n"; next }
    { printf "%s", held; held = ""; print }' "$1"
}
