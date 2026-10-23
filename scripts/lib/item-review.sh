# shellcheck shell=bash
# The half of an item review every kind shares. A batch of edits
# (batch-edit.sh) and a round of /anchor:review (review-round.sh) each put one
# item per row of a table in revdiff, a note in the diff on each item, and read
# back what the reviewer did to the row and the notes. What an item is, and what
# a kept one becomes, stays with the script that owns the kind.
#
# Sourced only; the caller sources lib/tmpfile.sh first.

# The tree under <root> as it stands, as a tree object, without touching the
# real index. The table is the reviewer's to edit and never part of an item.
anchor_items_snapshot() {
  local root="$1" table="$2" idx tree
  idx=$(anchor_tmpfile anchor-items-index idx)
  GIT_INDEX_FILE="$idx" git -C "$root" read-tree HEAD
  GIT_INDEX_FILE="$idx" git -C "$root" add -A -- . ":(exclude)$table"
  tree=$(GIT_INDEX_FILE="$idx" git -C "$root" write-tree)
  rm -f "$idx"
  printf '%s' "$tree"
}

# Every changed line between two trees, as `<file>\t<+|->\t<line>` rows, under
# any pathspecs that follow.
anchor_items_changed_lines() {
  git -C "$1" -c core.quotePath=false diff -U0 --no-color --no-renames "$2" "$3" -- "${@:4}" | awk '
    /^--- / { old = substr($0, 5); sub(/\t$/, "", old); sub(/^a\//, "", old); next }
    /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); if (f == "/dev/null") f = old; else sub(/^b\//, "", f); next }
    /^@@ / {
      split($2, o, ","); split($3, n, ",")
      ol = substr(o[1], 2) + 0; nl = substr(n[1], 2) + 0; next
    }
    /^\+/ { print f "\t+\t" nl; nl++; next }
    /^-/  { print f "\t-\t" ol; ol++; next }
  '
}

# Where revdiff shows a note about <line> of <file> in <tree>, printed as
# `<marker>\t<line>`. revdiff draws a note under its line, so a note about line N
# sits on line N-1, and the marker has to match that line's side of the diff or
# revdiff drops the note. A line it has nowhere to show prints why and returns 1.
anchor_items_anchor() {
  local lines="$1" root="$2" tree="$3" file="$4" line="$5" side="$6" at count
  if [[ "$side" == old ]]; then
    grep -qxF -- "${file}	-	${line}" "$lines" || { echo "not a removed line"; return 1; }
    printf -- '-\t%s\n' "$line"
    return 0
  fi
  count=$(git -C "$root" cat-file -p "$tree:$file" 2>/dev/null | awk 'END { print NR }')
  (( line >= 1 && line <= ${count:-0} )) || { echo "not a line of the file (${count:-0} lines)"; return 1; }
  at=$(( line > 1 ? line - 1 : 1 ))
  if grep -qxF -- "${file}	+	${at}" "$lines"; then
    printf '+\t%s\n' "$at"
  else
    printf ' \t%s\n' "$at"
  fi
}

# TEMPORARY: works around https://github.com/umputun/revdiff/issues/405, where
# revdiff's `]` steps from hunk to hunk and passes every note outside one.
# Remove this and its callers' handling of `far` once `]` stops at annotations;
# notes then stay on the lines they concern.
#
# Rewrites the notes JSON in place:
#   - a note on a whole file moves onto that file's first changed line no other
#     note holds, keeps `about: "file"`, and says so on its second line, after
#     the header the readers match on;
#   - a note within anchor_items_near lines of a change stays where it is, since
#     it is on screen when `]` lands on that change;
#   - a note further from every change than that is marked `far`, for the caller
#     to show somewhere `]` can't skip, rather than on code it isn't about.
anchor_items_near=3
anchor_items_onto_hunks() {
  local notes="$1" lines="$2" moved
  moved=$(jq --rawfile l "$lines" --argjson near "$anchor_items_near" '
    ($l | split("\n") | map(select(length > 0) | split("\t") | {file:.[0], side:.[1], line:(.[2] | tonumber)})) as $rows
    | def slot: "\(.file)\t\(.marker)\t\(.line)";
      def changes($f): [$rows[] | select(.file == $f)] | (map(select(.side == "+")) as $p | if ($p | length) > 0 then $p else . end);
    reduce .[] as $n ({taken: (map(select(.marker != "file") | slot)), out: []};
      if $n.marker == "file" then
        . as $acc
        | (changes($n.file) | sort_by(.line)
           | map(select(("\($n.file)\t\(.side)\t\(.line)") as $k | $acc.taken | index($k) | not)) | first) as $h
        | if $h == null then .out += [$n]
          else .taken += ["\($n.file)\t\($h.side)\t\($h.line)"]
            | .out += [$n + {line:$h.line, marker:$h.side, side:(if $h.side == "-" then "old" else "new" end), about:"file",
                             body:($n.body | split("\n") | [.[0], "↪ about \($n.where // "the whole file")"] + .[1:] | join("\n"))}]
          end
      elif $n.marker == " " then
        (changes($n.file) | map((.line - $n.line) | fabs) | min) as $d
        | if $d != null and $d <= $near then .out += [$n] else .out += [$n + {far:true}] end
      else .out += [$n] end)
    | .out' "$notes")
  printf '%s\n' "$moved" > "$notes"
}

# The notes JSON ({file, line, marker, body}) as the markdown revdiff preloads.
anchor_items_notes_md() {
  jq -r '.[] | (if .marker == "file" then "## \(.file) (file-level)" else "## \(.file):\(.line) (\(.marker))" end)
         + "\n" + (.body | gsub("\n## "; "\n ## ")) + "\n"' "$1"
}

# The table file opens with a title and how to answer.
anchor_items_intro() {
  printf '# %s\n%s\n' "$1" "$2"
}

# A header row, then the item rows read from stdin, one per item, each opening
# with its id cell.
anchor_items_rows() {
  printf '%s\n' "$1"
  cat
}

anchor_items_table() {
  anchor_items_intro "$1" "$2"
  anchor_items_rows "$3"
}

# One `<DECISION>=<ids>` line per decision named, from a read's items.
anchor_items_decisions() {
  local read="$1" d
  shift
  for d in "$@"; do
    jq -r --arg d "$d" \
      '"\($d | ascii_upcase)=\([.items[] | select(.decision == $d) | .id | tostring] | join(","))"' "$read"
  done
}

# jq definitions both readers share, prepended to their filters.
#   rowid      a table line's id: its first cell, unescaped; not the header's `#`
#   rowmap     a table's text as [{id, row}], one per item row
#   rowof($tl) the id of the row a returned table note sits on, in table lines $tl
#   rowedited  whether a row's text changed, ignoring whitespace
#   decision   drop for a deleted row, change for any feedback, else $otherwise
# shellcheck disable=SC2016
ANCHOR_ITEMS_JQ='
  def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  def rowid: select(test("^\\|[-|: ]+$") | not)
    | capture("^\\|(?<c>(?:\\\\.|[^|\\\\])*)\\|").c
    | sub("^\\s+"; "") | sub("\\s+$"; "") | gsub("\\\\\\|"; "|") | select(. != "#");
  def rowmap: split("\n") | map((rowid? // null) as $id | select($id != null) | {id:$id, row:.});
  def rowof($tl): (.startLine // 0) as $n
    | if $n > 0 then (($tl[$n-1] // "") | (rowid? // null)) else null end;
  def rowedited($was; $now): $now != null and $was != null and (($now|norm) != ($was|norm));
  def decision($row; $feedback; $otherwise):
    if $row == null then "drop" elif $feedback then "change" else $otherwise end;
  def answerwords: ascii_downcase | gsub("^\\s+"; "") | gsub("[\\s.!]+$"; "");
  def dropword: IN("drop", "ignore", "leave", "leave it", "skip", "no", "nope", "reject",
                   "wontfix", "won\u0027t fix", "-1", "\ud83d\udc4e", ":thumbsdown:", "\u274c");
  def keepword: IN("ok", "okay", "yes", "y", "apply", "keep", "lgtm", "sure", "fine",
                   "+1", "\ud83d\udc4d", ":thumbsup:", "\u2705", "ship it", "do it");
  # What a returned note says about the note seeded where it sits: the lines the
  # reviewer added, read as an answer. A bare drop word drops, a bare yes keeps,
  # anything else is feedback, and nothing added leaves it as seeded.
  def answer($seeded):
    ((split("\n") - ($seeded | split("\n"))) | map(select(test("\\S"))) | join(" ") | answerwords) as $a
    | if $a == "" then "same" elif ($a | dropword) then "drop" elif ($a | keepword) then "keep" else "change" end;
'
