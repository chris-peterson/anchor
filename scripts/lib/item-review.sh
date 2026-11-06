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

# Whether <file> sits under one of the <path>s that follow; no paths is the whole
# repo.
anchor_items_in_scope() {
  local f="$1" p
  shift
  [[ $# -gt 0 ]] || return 0
  for p in "$@"; do
    p="${p%/}"
    [[ "$f" == "$p" || "$f" == "$p"/* ]] && return 0
  done
  return 1
}

# Whether <file> has a row in the changed-lines file anchor_items_changed_lines
# wrote.
anchor_items_file_changed() {
  awk -F'\t' -v f="$2" '$1 == f { found = 1; exit } END { exit !found }' "$1"
}

# Where line <line> of <file> in <from> stands in <to>: shifted past the lines
# changed above it. A line a change rewrote follows to the first line of what
# replaced it, or prints `null` when <rewritten> is `null`.
anchor_items_follow_line() {
  git -C "$1" -c core.quotePath=false diff -U0 --no-color --no-renames "$2" "$3" -- ":/$4" \
    | awk -v L="$5" -v rewritten="${6:-first}" '
      /^@@ / {
        split($2, o, ","); split($3, n, ",")
        a = substr(o[1], 2) + 0; b = (o[2] == "" ? 1 : o[2] + 0)
        c = substr(n[1], 2) + 0; d = (n[2] == "" ? 1 : n[2] + 0)
        if (b == 0) { if (L <= a) exit; delta += d; next }
        if (L < a) exit
        if (L <= a + b - 1) { hit = 1; at = (rewritten == "null" ? "null" : (c > 0 ? c : 1)); exit }
        delta += d - b
      }
      END { print (hit ? at : L + delta) }'
}

# Lines <from>..<to> of <file> in <rev>, three either side, numbered, with the
# lines from..to marked.
anchor_items_excerpt() {
  git -C "$1" cat-file -p "$2:$3" | awk -v a="$4" -v b="$5" '
    NR >= a - 3 && NR <= b + 3 { printf "%s %4d  %s\n", (NR >= a && NR <= b ? ">" : " "), NR, $0 }'
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
