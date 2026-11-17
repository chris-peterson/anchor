#!/usr/bin/env bash
# The Review status section of a CR description: each commit on the CR, how many
# review rounds it has been in, who reviewed it, the result, kind, and time of
# the latest one, and the decisions a review recorded on it. A round is an
# intentional review, through /anchor:review, and its kind says how it was made:
# `agent-assisted` when the reviewer read the range and quality agents examined
# it, `read-through` when only the reviewer read it, and `agents-only` when the
# agents examined it and the reviewer decided their findings without reading the
# range again. A review of a range gives every commit in it another round, so a
# commit reviewed on its own and again as part of the whole change counts both.
#
# Every round, and every commit mark, carries `v`: the anchor version that wrote
# it. The record outlives the plugin that wrote it, so a reader meeting data a
# later version shaped differently, or one that a bug wrote wrong, can tell which
# entries to read which way. An entry with no `v` was written by 2.0.0 or
# earlier, which recorded /anchor:commit's review as an agent-assisted round.
#
# The look a commit gets when /anchor:commit makes it is not a round. It is
# recorded apart, as `committed: {by, at}`: the bar for an incremental commit is
# not the bar for a review the user set out to make, so it neither counts as one
# nor lets a later review skip the commit. /anchor:review reads it to say when
# the user last looked at a commit, and asks rather than assuming either way.
#
# A commit is keyed by its sha, and its entry carries `patch`, the commit's
# `git patch-id`: a hash of the change itself, which stays the same when a rebase
# moves the commit and changes when an amend changes it. A commit with no entry
# under its sha takes the one whose `patch` matches, so a rebase keeps its rounds
# and an amend starts again at none; the next write moves the entry to the new
# sha. Data written by 2.0.1 or earlier is keyed by the patch-id itself, and is
# read the same way.
#
# The section is one HTML comment the forge doesn't render, so the record stays
# out of the author's prose; /anchor:review and /anchor:merge are where it is
# read. Inside it is a JSON object, one commit per line, so deleting the comment's
# first and last lines leaves JSON:
#
#   <!-- anchor:review-status
#   {
#   "<sha>": {"patch":"<patch-id>","rounds":1,"by":["me"],...},
#   "<sha>": {"patch":"<patch-id>","committed":{"by":["me"],...}}
#   }
#   -->
#
# Data written by 2.0.1 or earlier sits on the comment's one line, and is read
# the same.
#
# Sourced only. Every function reads the repo in the current directory.
#
#   review_status_has <description file>
#                         whether the description has the section
#   review_status_data <description file>
#                         the recorded rounds as {"<sha>": {patch, rounds, by,
#                         result, kind, at, committed, notes}}; {} for a
#                         description without the section
#   review_status_rekey <data json> <base> <head>
#                         the data with each commit in <base>..<head> that has
#                         an entry under its own sha, carrying its patch-id, and
#                         those entries last, oldest first
#   review_status_rows <data json> <base> <head>
#                         the commits in <base>..<head>, oldest first, as
#                         [{sha, patch, rounds, by, result, kind, at, v, committed,
#                         notes}], 0 rounds where unrecorded and `committed` null
#                         where no commit review was recorded. A round recorded
#                         without a kind reads as agent-assisted, and one
#                         recorded without a time has `at` empty
#   review_status_add <data json> <base> <head> <result> <kind> <reviewer> [<note>...]
#                         the data with every commit in <base>..<head> given
#                         another round by <reviewer> whose result is <result>
#                         and kind is <kind>, timed now, and each <note> added
#                         to the newest of them. Kind `commit` gives no round:
#                         it marks each commit `committed` by <reviewer> now,
#                         and takes no notes
#   review_status_notes <data json>
#                         every note recorded, on any commit, as a JSON array
#   review_status_section <data json>
#                         the section: one comment carrying the data, a commit
#                         to a line
#   review_status_splice <description file> <section file>
#                         the description with its section replaced by the new
#                         one, or the new one appended where it had none
#   review_status_strip <description file> <section file>
#                         the description without its section, which goes to
#                         <section file>; that file is empty where it had none
#   review_status_pick <data json> <base> <head>
#                         the data for the commits in <base>..<head> alone
#   review_status_local_path
#                         the branch-less record kept in the repo's git directory
#   review_status_local_data
#                         that record's data; {} where there is none yet
#   review_status_local_write <data json>
#                         replace that record with <data json>
#
# A branch with no CR keeps its rounds in the local record, in the same shape
# and under the same keys, until /anchor:prepare-review opens the CR and carries
# them into its section. The record sits in the git common directory, so every
# worktree of the repo reads the same one, and it holds every branch's commits,
# so the readers pick out the range they want.

REVIEW_STATUS_MARK="anchor:review-status"

# The version of anchor writing a record, from the plugin's own manifest.
review_status_version() {
  local manifest
  manifest="$(dirname "${BASH_SOURCE[0]}")/../../.claude-plugin/plugin.json"
  jq -r '.version // "unknown"' "$manifest" 2>/dev/null || echo unknown
}

# One "<sha> <patch-id>" line per commit, oldest first. A commit with no diff has
# no patch-id, so its sha stands in for one.
review_status_keys() {
  awk 'FILENAME == ARGV[1] { key[$2] = $1; next } { print $0, ($0 in key ? key[$0] : $0) }' \
    <(git log -p --no-merges --format='commit %H' "$1..$2" | git patch-id --stable) \
    <(git rev-list --reverse --no-merges "$1..$2")
}

# rekey($d; $commits): $commits is [[sha, patch-id], ...], oldest first. Each
# commit's entry is the one under its sha, else the one whose `patch` is its
# patch-id, else (data written by 2.0.1 or earlier) the one keyed by the
# patch-id. The entry found leaves its old key and lands under the sha, so a
# rebased commit's rounds follow it and the record holds no copy under the sha
# it had.
# shellcheck disable=SC2016 # jq source, not shell
REVIEW_STATUS_JQ='
def rekey($d; $commits):
  (reduce $commits[] as $c ({src: [], found: []};
     $c[0] as $sha | $c[1] as $patch
     | (if $d[$sha] != null then $sha
        else (first($d | to_entries[] | select(.value.patch == $patch) | .key)
              // (if $d[$patch] != null then $patch else null end))
        end) as $k
     | if $k == null then .
       else .src += [$k] | .found += [{key: $sha, value: ({patch: $patch} + $d[$k] + {patch: $patch})}] end)) as $r
  | ($d | with_entries(select(.key as $k | $r.src | index([$k]) | not))) + ($r.found | from_entries);
'

# The section's lines, from its opening line through the one that closes it,
# with any carriage return a forge's editor left taken off.
review_status_block() {
  awk -v open="<!-- $REVIEW_STATUS_MARK" '
    { line = $0; sub(/\r$/, "", line) }
    !inside && (index(line, open " ") == 1 || line == open) { inside = 1 }
    inside { print line; if (line ~ /-->[[:space:]]*$/) exit }' "$1"
}

review_status_has() {
  [[ -n "$(review_status_block "$1")" ]]
}

review_status_data() {
  local block
  block=$(review_status_block "$1")
  if [[ -z "$block" ]]; then
    echo '{}'
    return
  fi
  block=${block#"<!-- $REVIEW_STATUS_MARK"}
  jq -c . <<<"${block%-->*}"
}

review_status_rekey() {
  review_status_keys "$2" "$3" | jq -Rnc --argjson d "$1" "$REVIEW_STATUS_JQ"'[inputs | split(" ")] as $c | rekey($d; $c)'
}

review_status_rows() {
  review_status_keys "$2" "$3" | jq -Rnc --argjson d "$1" "$REVIEW_STATUS_JQ"'
    [inputs | split(" ")] as $c | rekey($d; $c) as $d
    | [$c[] | {sha: .[0], patch: .[1]} | ($d[.sha] // {}) as $e
       | . + {rounds: ($e.rounds // 0), by: ($e.by // []), result: ($e.result // ""),
              kind: (if ($e.rounds // 0) == 0 then "" else ($e.kind // "agent-assisted") end),
              at: (if ($e.rounds // 0) == 0 then "" else ($e.at // "") end),
              v: (if ($e.rounds // 0) == 0 then "" else ($e.v // "") end),
              committed: ($e.committed // null),
              notes: ($e.notes // [])}]'
}

# A decision is about the change as the round saw it, so it rides on the newest
# commit the round reviewed. A commit review is kept apart from the rounds, so
# neither the round count nor the reviewers a later review reads move for it.
review_status_add() {
  local data="$1" from="$2" to="$3" result="$4" kind="$5" reviewer="$6" now ver
  shift 6
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ver=$(review_status_version)
  review_status_keys "$from" "$to" | jq -Rnc --argjson d "$data" --arg r "$result" --arg kind "$kind" --arg w "$reviewer" \
    --arg now "$now" --arg ver "$ver" --args "$REVIEW_STATUS_JQ"'[inputs | split(" ")] as $c
    | [$c[] | .[0]] as $keys
    | rekey($d; $c) as $d
    | ($c | map({key: .[0], value: .[1]}) | from_entries) as $patch
    | $d
    | if $kind == "commit" then
        reduce $keys[] as $k ($d;
          (.[$k].committed.by // []) as $by
          | .[$k].patch = $patch[$k]
          | .[$k].committed = {by: (if ($by | index([$w])) then $by else $by + [$w] end), at: $now, v: $ver})
      else
        reduce $keys[] as $k ($d;
          (.[$k].by // []) as $by
          | .[$k] = ({patch: $patch[$k]} + .[$k] + {rounds: ((.[$k].rounds // 0) + 1),
                              by: (if ($by | index([$w])) then $by else $by + [$w] end),
                              result: $r, kind: $kind, at: $now, v: $ver}))
        | if ($keys | length) > 0 and ($ARGS.positional | length) > 0
          then .[$keys[-1]].notes = ((.[$keys[-1]].notes // []) + $ARGS.positional)
          else . end
      end' "$@"
}

review_status_notes() {
  jq -c '[.[] | .notes // [] | .[]]' <<<"$1"
}

# A commit the CR no longer has keeps its entry in the data, so one that comes
# back unchanged keeps what it had. The data's `>` is written as its JSON escape,
# so a note holding `-->` can't close the comment that carries it, and the lines
# between the comment's first and last still parse as JSON.
review_status_section() {
  printf '<!-- %s\n' "$REVIEW_STATUS_MARK"
  jq -r 'if length == 0 then "{\n}"
         else "{\n" + ([to_entries[] | "\(.key | tojson): \(.value | tojson)"] | join(",\n")) + "\n}" end' <<<"$1" \
    | sed 's/>/\\u003e/g'
  printf -- '-->\n'
}

# The section is replaced where it stands, from its opening line through the one
# that closes it, whichever shape an earlier version wrote it in.
review_status_splice() {
  if review_status_has "$1"; then
    awk -v open="<!-- $REVIEW_STATUS_MARK" -v section="$2" '
      { line = $0; sub(/\r$/, "", line) }
      !done && !inside && (index(line, open " ") == 1 || line == open) {
        inside = 1; while ((getline l < section) > 0) print l
      }
      inside { if (line ~ /-->[[:space:]]*$/) { inside = 0; done = 1 }; next }
      { print }' "$1"
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
  awk -v open="<!-- $REVIEW_STATUS_MARK" -v out="$2" '
    { line = $0; sub(/\r$/, "", line) }
    !done && !inside && (index(line, open " ") == 1 || line == open) { inside = 1 }
    inside { print > out; if (line ~ /-->[[:space:]]*$/) { inside = 0; done = 1 }; next }
    /^[[:space:]]*$/ { held = held $0 "\n"; next }
    { printf "%s", held; held = ""; print }' "$1"
}

review_status_pick() {
  [[ "$1" != '{}' ]] || { echo '{}'; return; }
  review_status_keys "$2" "$3" | jq -Rnc --argjson d "$1" "$REVIEW_STATUS_JQ"'
    [inputs | split(" ")] as $c | [$c[] | .[0]] as $keys
    | rekey($d; $c) | with_entries(select(.key as $k | $keys | index([$k])))'
}

review_status_local_path() {
  printf '%s/anchor/review-status.json\n' "$(cd "$(git rev-parse --git-common-dir)" && pwd)"
}

review_status_local_data() {
  local path
  path=$(review_status_local_path)
  if [[ -s "$path" ]]; then
    jq -c . "$path"
  else
    echo '{}'
  fi
}

# Written beside the record and renamed over it, so a session that dies
# mid-write leaves the previous record rather than half of a new one.
review_status_local_write() {
  local path
  path=$(review_status_local_path)
  mkdir -p "$(dirname "$path")"
  jq -c . <<<"$1" > "$path.tmp.$$"
  mv "$path.tmp.$$" "$path"
}
