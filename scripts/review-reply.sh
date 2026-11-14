#!/usr/bin/env bash
# Seed the reply to a `changes-requested` changeset review (DIFF-37): each of
# the reviewer's notes, what became of it, and where in the next review's diff
# the answer sits. review-diff.sh --reply then opens that review on what changed
# after the last one closed, with these replies preloaded as notes and listed at
# the top of its context file.
#
# The skill decides what each reply says and where it belongs; this script holds
# it to answering every note, anchors each answer where revdiff can show it, and
# writes the files the review reads.
#
# Usage:
#   review-reply.sh --state <dir> --replies <replies.json> [--path <p>...] [--repo <path>]
#
# <dir> is the REVIEW_STATE the review printed. The --path list is the one the
# next review will be given: the replies are anchored in what it shows.
#
# The replies file, written by the skill, answers the review's comments by their
# 1-based position in REVIEW_OUTPUT's comments array:
#   {"replies": [{"comment": 1, "status": "answered|done|different",
#                 "reply": "<the answer, or what was done and why>",
#                 "sites": [{"file": "<path>", "line": <n>, "side": "new|old"},
#                           {"file": "<path>"}]}]}
#   answered   a question; the reply is the answer
#   done       the change was made as asked
#   different  the change went another way, or not at all; the reply says why
# A site is a line the reply is about, numbered in the tree as it now stands
# (a site with no line is a note on the whole file). With no sites, the reply
# goes where the reviewer's note was, following it past the lines that moved,
# and a note on no file is answered in the context file alone.
#
# A reply in a file with no change since the last review is answered in the
# context file too, with the lines it is about quoted under it: revdiff shows a
# file with no diff in full, so placing the reply there would put the whole file
# back in front of the reviewer to show them one answer.
#
# Output is KEY=value lines. Every reply that can't be placed prints its own
# REPLY_ERROR=<message>, and the script exits 65 having written nothing.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/stage-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-paths.sh"
# shellcheck source=lib/item-review.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/item-review.sh"

CTX_REPO="" state="" replies=""
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --state)   state="${2:?--state needs the REVIEW_STATE dir}"; shift 2 ;;
    --replies) replies="${2:?--replies needs a file}"; shift 2 ;;
    --path)    paths+=("${2:?--path needs a path}"); shift 2 ;;
    *) echo "review-reply.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$state" && -s "$state/reviewed" && -f "$state/comments.json" ]] \
  || { echo "review-reply.sh: --state must name the REVIEW_STATE a changes-requested review printed" >&2; exit 64; }
[[ -n "$replies" && -r "$replies" ]] || { echo "review-reply.sh: --replies needs a readable file" >&2; exit 64; }
ctx_resolve_repo
anchor_reject_absolute review-reply.sh "${paths[@]+"${paths[@]}"}" || exit $?
root=$(git rev-parse --show-toplevel)
comments="$state/comments.json"

problems=$(jq -r --slurpfile c "$comments" '
  ($c[0] | length) as $n
  | (.replies // []) as $r
  | (([range(1; $n + 1)] - [$r[].comment])[]
       | "comment \(.) has no reply: \($c[0][. - 1].body | split("\n")[0])"),
    ($r | group_by(.comment)[] | select(length > 1) | "comment \(.[0].comment) has \(length) replies"),
    ($r[] | select((.comment | type) != "number" or .comment < 1 or .comment > $n)
       | "no comment \(.comment) to reply to; the review returned \($n)"),
    ($r[] | select(.status | IN("answered", "done", "different") | not)
       | "the reply to comment \(.comment) has status \(.status); it takes answered, done, or different"),
    ($r[] | select((.reply // "") | test("\\S") | not) | "the reply to comment \(.comment) is empty")
' "$replies")
if [[ -n "$problems" ]]; then
  while IFS= read -r line; do echo "REPLY_ERROR=$line"; done <<<"$problems"
  exit 65
fi

reviewed=$(cat "$state/reviewed")
now=$(anchor_review_snapshot "${paths[@]+"${paths[@]}"}")
specs=()
for p in "${paths[@]+"${paths[@]}"}"; do specs+=(":/$p"); done
lines="$state/changed.tsv"
anchor_items_changed_lines "$root" "$reviewed" "$now" "${specs[@]+"${specs[@]}"}" > "$lines"

# Where line <n> of <file> as the reviewer saw it stands now.
follow_line() { anchor_items_follow_line "$root" "$reviewed" "$now" "$1" "$2"; }

rows=$(jq -r --slurpfile c "$comments" '
  .replies[] as $r | ($c[0][$r.comment - 1]) as $cm
  | if (($r.sites // []) | length) > 0 then
      ($r.sites | to_entries[] | [$r.comment, .key, .value.file, (.value.line // ""), (.value.side // "new"), "given"])
    elif $cm.file != null and $cm.target == "line" and $cm.side != "old" then
      [$r.comment, 0, $cm.file, ($cm.endLine // $cm.startLine), "new", "asked", ($cm.startLine // $cm.endLine)]
    elif $cm.file != null then
      [$r.comment, 0, $cm.file, "", "new", "asked"]
    else empty end
  | map(tostring) | join("\u001f")' "$replies")

# Each placed site as `<comment>\t<k>\t<file>\t<marker>\t<line>\t<where>`, where
# <where> is the line the reply is about, for the context file's table. A reply
# kept out of the diff is one `{id, where, excerpt}` per line of $quoted.
anchors="$state/anchors.tsv"; : > "$anchors"
quoted="$state/quoted.jsonl"; : > "$quoted"
errors=()
while IFS=$'\x1f' read -r cid k file line side kind start; do
  [[ -n "$cid" ]] || continue
  if ! anchor_items_in_scope "$file" "${paths[@]+"${paths[@]}"}"; then
    errors+=("comment $cid: $file is not one of the paths under review"); continue
  fi
  if [[ "$side" != old ]] && ! git cat-file -e "$now:$file" 2>/dev/null; then
    errors+=("comment $cid: $file is not in the tree any more, so revdiff has nowhere to show the reply"); continue
  fi
  if ! anchor_items_file_changed "$lines" "$file"; then
    if [[ -z "$line" ]]; then
      jq -nc --argjson id "$cid" --arg w "$file" '{id:$id, where:$w, excerpt:null}' >> "$quoted"
      continue
    fi
    if [[ "$kind" == asked ]]; then
      to=$(follow_line "$file" "$line"); from=$(follow_line "$file" "${start:-$line}")
    else
      from=$line to=$line
    fi
    where="$file:$from"; [[ "$from" == "$to" ]] || where+="-$to"
    jq -nc --argjson id "$cid" --arg w "$where" --arg x "$(anchor_items_excerpt "$root" "$now" "$file" "$from" "$to")" \
      '{id:$id, where:$w, excerpt:$x}' >> "$quoted"
    continue
  fi
  if [[ -z "$line" ]]; then
    printf '%s\t%s\t%s\tfile\t\t%s\n' "$cid" "$k" "$file" "$file" >> "$anchors"; continue
  fi
  if [[ "$kind" == given ]]; then
    if ! at=$(anchor_items_anchor "$lines" "$root" "$now" "$file" "$line" "$side"); then
      errors+=("comment $cid: $file:$line: $at"); continue
    fi
    printf '%s\t%s\t%s\t%s\t%s:%s\n' "$cid" "$k" "$file" "$at" "$file" "$line" >> "$anchors"
    continue
  fi
  # Under the line the reviewer's note was on, where revdiff drew it.
  at=$(follow_line "$file" "$line")
  count=$(git cat-file -p "$now:$file" | awk 'END { print NR }')
  (( at <= count )) || at=$count
  marker=" "
  grep -qxF -- "${file}	+	${at}" "$lines" && marker="+"
  printf '%s\t%s\t%s\t%s\t%s\t%s:%s\n' "$cid" "$k" "$file" "$marker" "$at" "$file" "$at" >> "$anchors"
done <<<"$rows"
if [[ ${#errors[@]} -gt 0 ]]; then
  for e in "${errors[@]}"; do echo "REPLY_ERROR=$e"; done
  exit 65
fi

# The notes, in revdiff's markdown and as JSON the review compares its returned
# notes against. One note per reply, on its first site, naming the others: a
# note at each site that only points back to the first fills the annotation
# list with copies of one #N, which reads as notes left over from earlier rounds.
#
# Each reply is numbered in the order revdiff lists it, by path and then line,
# with the replies the diff has no line for numbered after them, so the
# annotation list and the table both count up from #1. The number is the
# reply's own; the reviewer's comment is still named by its position (.id).
jq -n --slurpfile r "$replies" --slurpfile c "$comments" --rawfile a "$anchors" '
  def outcome: {answered:"answered", done:"🏁 as asked", different:"⚠️ done differently"}[.];
  ($a | split("\n") | map(select(length > 0) | split("\t")
    | {id:(.[0]|tonumber), k:(.[1]|tonumber), file:.[2], marker:.[3],
       line:(if .[4] == "" then null else (.[4]|tonumber) end), where:.[5]})) as $anchors
  | [$r[0].replies[] as $x
     | ($anchors | map(select(.id == $x.comment)) | sort_by(.k)) as $mine
     | select($mine | length > 0)
     | $mine[0] as $s
     | {id:$x.comment, file:$s.file, line:$s.line, marker:$s.marker, where:$s.where,
        also:($mine[1:] | map(.where)), status:$x.status, reply:$x.reply}]
  | sort_by([.file, (.line // 0), .id]) | to_entries
  | map(.value + {n:(.key + 1)}
        | . + {body:("🤖 #\(.n) · \(.status | outcome)\nYou asked: \($c[0][.id - 1].body)\n\n\(.reply)"
                     + (if (.also | length) > 0 then "\n\nAlso at: \(.also | join(", "))" else "" end))}
        | del(.status, .reply))
' > "$state/notes.json"
anchor_items_notes_md "$state/notes.json" > "$state/notes.md"

# Every reply with its number, the placed ones first in their diff order.
order=$(jq -c --slurpfile n "$state/notes.json" '
  ($n[0] | map({key:(.id | tostring), value:.n}) | from_entries) as $placed
  | ([.replies[].comment | select(($placed[tostring]) == null)] | sort) as $rest
  | $placed + ($rest | to_entries | map({key:(.value | tostring), value:(.key + 1 + ($placed | length))}) | from_entries)
' "$replies")

# The context file's half. The table goes at its head (reply-head.md), so the
# numbers are in view as it opens; the replies the diff has no line for go at its
# end (reply.md), each quoting the lines it is about where it has some.
jq -r --slurpfile n "$state/notes.json" --slurpfile c "$comments" --slurpfile q "$quoted" --argjson o "$order" '
  def outcome: {answered:"answered", done:"🏁 as asked", different:"⚠️ done differently"}[.];
  def cell: gsub("\n"; " ") | gsub("\\|"; "\\|");
  (.replies | sort_by($o[.comment | tostring])) as $rs
  | ([$rs[] | .comment as $i | select([$n[0][] | select(.id == $i)] | length == 0)] | length) as $off
  | "# Reply to your review",
    "What I did with each of your notes; each reply is on its line in the diff\(if $off > 0 then ", or at the end of this file" else "" end). Leave a note on one to answer it.",
    "| # | you asked | what I did | where |",
    ($rs[] | . as $x
      | ([$n[0][] | select(.id == $x.comment)] | first) as $note
      | ($note.where // null) as $w
      | ([$q[] | select(.id == $x.comment)] | first | .where // null) as $qw
      | "| \($o[$x.comment | tostring]) | \($c[0][$x.comment - 1].body | split("\n")[0] | cell) | \($x.status | outcome) | \(if $w then ([$w] + ($note.also // []) | map("`\(.)`") | join(", ")) elif $qw then "end of file, `\($qw)`" else "end of file" end) |")
' "$replies" > "$state/reply-head.md"
jq -r --slurpfile n "$state/notes.json" --slurpfile c "$comments" --slurpfile q "$quoted" --argjson o "$order" '
  def outcome: {answered:"answered", done:"🏁 as asked", different:"⚠️ done differently"}[.];
  [.replies | sort_by($o[.comment | tostring])[] | . as $x | select([$n[0][] | select(.id == $x.comment)] | length == 0)] as $off
  | if ($off | length) == 0 then empty else
      "# Replies with no line in the diff",
      ($off[] | . as $x
        | ([$q[] | select(.id == $x.comment)] | first) as $qx
        | "## #\($o[$x.comment | tostring]) · \($x.status | outcome)",
          (if $qx then "`\($qx.where)`, unchanged since your review:" else empty end),
          (if $qx.excerpt then ($qx.excerpt | rtrimstr("\n")) else empty end),
          "You asked: \($c[0][$x.comment - 1].body)", "", $x.reply)
    end
' "$replies" > "$state/reply.md"

echo "REPLY_STATE=$state"
echo "NOTE_COUNT=$(jq length "$state/notes.json")"
echo "IN_CONTEXT_ONLY=$(jq --slurpfile n "$state/notes.json" '[.replies[] | .comment as $i | select([$n[0][] | select(.id == $i)] | length == 0)] | length' "$replies")"
