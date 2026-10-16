#!/usr/bin/env bash
# The deterministic half of one round of /anchor:review: where the review's
# edits are made, what each finding changed, the notes revdiff shows, and what
# the reviewer's notes said when the review closed. The skill decides what each
# finding is and how to fix it; this script keeps the record of it.
#
# A round is a directory of state (ROUND_DIR) and a tree the edits land in
# (ROUND_ROOT). On the user's own CR the tree is their checkout, which has to be
# on the CR head with nothing uncommitted, so a round's edits are the only
# changes in it. On someone else's CR it is a worktree at the CR head in a temp
# directory, so the user's checkout is never touched.
#
# Each finding the skill applies is recorded as its own patch, taken as the
# difference between two snapshots of the tree. A snapshot is a tree object
# written through a private index, so recording never stages anything. The
# patches are what let one finding be reverted after the others have landed, and
# what turns a single-hunk fix on someone else's CR into a suggestion.
#
# Rounds are counted. The first `start` writes a ledger (ROUND_LEDGER) holding
# the size of the CR's own diff; each later `start` given that ledger is the next
# round, and each `finish` appends what its round did: the items by status, what
# the reviewer's notes said and how much they wrote, and how many lines the round
# changed, as a percent of the CR's diff. Re-review loops that keep finding things
# to polish show up as a percent that stops falling. The ledger lives in the temp
# dir for as long as the session carries its path; nothing else reads it.
#
# Usage:
#   review-round.sh start   --base <sha> --head <sha> (--worktree | --in-place) [--ledger <file>] [--repo <path>]
#   review-round.sh record  --dir <round> --id <n>
#   review-round.sh revert  --dir <round> --id <n>
#   review-round.sh seed    --dir <round> --items <items.json> [--title <text>]
#   review-round.sh read    --dir <round> --returned <notes.returned.json>
#   review-round.sh suggest --dir <round> --id <n> --forge <github|gitlab>
#   review-round.sh files   --dir <round>
#   review-round.sh finish  --dir <round>
#   review-round.sh trend   --ledger <file>
#
# The items file `seed` reads, written by the skill:
#   {"items": [{"id": 1, "slug": "<kebab-case>", "severity": "important|consider|nit",
#               "status": "applied|proposed|issue|leave",
#               "finding": "<one line for the table>",
#               "reason": "<the note: why, and for a proposal what it would touch>",
#               "sites": [{"file": "<path>", "line": <n>, "side": "new|old"},
#                         {"file": "<path>"}]}]}
# A site's line is the first line of the edit (applied) or the line the change
# would go on (proposed), numbered in the tree as it now stands. A site with no
# line is a note on the whole file.
#
# Output is KEY=value lines on stdout. A failure prints ROUND_ERROR=<message>
# and exits non-zero rather than leaving a half-written round.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

TABLE=".review.md"

die() { echo "ROUND_ERROR=$*"; exit 65; }

cmd="${1:-}"
[[ -n "$cmd" ]] || { echo "usage: review-round.sh <start|record|revert|seed|read|suggest|files|finish> ..." >&2; exit 64; }
shift

CTX_REPO=""
dir="" base="" head="" place="" id="" items="" returned="" forge="" title="" ledger=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --dir)       dir="${2:?--dir needs a path}"; shift 2 ;;
    --base)      base="${2:?--base needs a sha}"; shift 2 ;;
    --head)      head="${2:?--head needs a sha}"; shift 2 ;;
    --worktree)  place=worktree; shift ;;
    --in-place)  place=in-place; shift ;;
    --id)        id="${2:?--id needs a number}"; shift 2 ;;
    --items)     items="${2:?--items needs a file}"; shift 2 ;;
    --returned)  returned="${2:?--returned needs a file}"; shift 2 ;;
    --forge)     forge="${2:?--forge needs github or gitlab}"; shift 2 ;;
    --title)     title="${2:?--title needs text}"; shift 2 ;;
    --ledger)    ledger="${2:?--ledger needs a file}"; shift 2 ;;
    *) echo "review-round.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

state() { jq -r --arg k "$1" '.[$k]' "$dir/round.json"; }
set_state() {
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$dir/round.json" > "$dir/round.json.tmp"
  mv "$dir/round.json.tmp" "$dir/round.json"
}

# The tree as it stands, as a tree object, without touching the real index. The
# table is the reviewer's to edit and never part of a finding.
snapshot() {
  local idx tree
  idx=$(anchor_tmpfile anchor-round-index idx)
  GIT_INDEX_FILE="$idx" git -C "$root" read-tree HEAD
  GIT_INDEX_FILE="$idx" git -C "$root" add -A -- . ":(exclude)$TABLE"
  tree=$(GIT_INDEX_FILE="$idx" git -C "$root" write-tree)
  rm -f "$idx"
  printf '%s' "$tree"
}

need_dir() {
  [[ -n "$dir" && -f "$dir/round.json" ]] || { echo "review-round.sh: --dir must name a round that start created" >&2; exit 64; }
  root=$(state root)
}

# Every changed line between two trees, as `<file>\t<+|->\t<line>` rows.
changed_lines() {
  git -C "$root" -c core.quotePath=false diff -U0 --no-color --no-renames "$1" "$2" | awk '
    /^--- / { old = substr($0, 5); sub(/^a\//, "", old); next }
    /^\+\+\+ / { f = substr($0, 5); if (f == "/dev/null") f = old; else sub(/^b\//, "", f); next }
    /^@@ / {
      split($2, o, ","); split($3, n, ",")
      ol = substr(o[1], 2) + 0; nl = substr(n[1], 2) + 0; next
    }
    /^\+/ { print f "\t+\t" nl; nl++; next }
    /^-/  { print f "\t-\t" ol; ol++; next }
  '
}

# Where a new-side line of the round's tree sits in the CR head: the same line
# shifted past the round's own edits above it, or nothing for a line a round
# edit added.
map_line() {
  local file="$1" line="$2"
  git -C "$root" -c core.quotePath=false diff -U0 --no-color --no-renames "$(state head)" "$(state lastTree)" -- "$file" \
    | awk -v L="$line" '
      /^@@ / {
        split($2, o, ","); split($3, n, ",")
        b = (o[2] == "" ? 1 : o[2] + 0); c = substr(n[1], 2) + 0; d = (n[2] == "" ? 1 : n[2] + 0)
        if (d > 0) { if (L < c) { done = 1; exit } if (L <= c + d - 1) { gone = 1; exit } delta += d - b }
        else { if (L <= c) { done = 1; exit } delta += -b }
      }
      END { if (gone) print "null"; else print L - delta }'
}

# The ledger's rounds as a markdown table, one row per round.
trend_table() {
  jq -r '
    "| Round | Items | Your notes | Lines changed | % of the CR |",
    "|---|---|---|---|---|",
    (.rounds[] | "| \(.n) | \(.items.applied) applied, \(.items.proposed) proposed | "
      + (if .notes == null then "not read" else
          "\(.notes.kept) kept, \(.notes.changed) changed, \(.notes.dropped) dropped, \(.notes.added) new (\(.notes.lines) lines)" end)
      + " | +\(.edits.added) −\(.edits.removed) in \(.edits.files) files | \(.percent)% |")' "$1"
}

case "$cmd" in

trend)
  [[ -n "$ledger" && -f "$ledger" ]] || { echo "review-round.sh trend needs the --ledger start printed" >&2; exit 64; }
  trend_table "$ledger"
  ;;

start)
  [[ -n "$base" && -n "$head" && -n "$place" ]] \
    || { echo "review-round.sh start needs --base, --head, and --worktree or --in-place" >&2; exit 64; }
  ctx_resolve_repo
  repo=$(git rev-parse --show-toplevel)
  git rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "the CR head $head is not in this checkout; run review-cr.sh first"
  diff_base=$(git merge-base "$base" "$head") || die "no merge base between $base and $head"
  if [[ "$place" == worktree ]]; then
    root="$(anchor_tmpdir anchor-review-tree)/tree"
    git worktree add --quiet --detach "$root" "$head" >/dev/null 2>&1 \
      || die "could not add a worktree at $head"
  else
    root="$repo"
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$head")" ]] \
      || die "this checkout is at $(git rev-parse --short HEAD), not the CR head $(git rev-parse --short "$head"); switch to the CR's branch and pull first"
    git diff --quiet HEAD -- || die "this checkout has uncommitted changes; commit or stash them first, so a round's edits are the only changes in it"
    [[ ! -e "$root/$TABLE" ]] || die "$TABLE already exists in $root; a previous round didn't finish (review-round.sh finish)"
  fi
  if [[ -z "$ledger" ]]; then
    ledger=$(anchor_tmpfile anchor-review-ledger json)
    cr_lines=$(git diff --numstat --no-renames "$diff_base" "$head" | awk '{ a += $1; d += $2 } END { print a + d + 0 }')
    jq -n --arg h "$(git rev-parse "$head")" --argjson l "$cr_lines" \
      '{firstHead:$h, crLines:$l, rounds:[]}' > "$ledger"
  fi
  [[ -f "$ledger" ]] || die "no ledger at $ledger; start the first round without --ledger"
  round_n=$(( $(jq '.rounds | length' "$ledger") + 1 ))
  dir=$(anchor_tmpdir anchor-review-round)
  t0=$(snapshot)
  jq -n --arg repo "$repo" --arg root "$root" --arg place "$place" \
    --arg base "$diff_base" --arg head "$(git rev-parse "$head")" --arg t "$t0" \
    --arg ledger "$ledger" --arg n "$round_n" \
    '{repo:$repo, root:$root, place:$place, diffBase:$base, head:$head, startTree:$t, lastTree:$t,
      ledger:$ledger, n:$n}' \
    > "$dir/round.json"
  mkdir -p "$dir/items"
  echo "ROUND_DIR=$dir"
  echo "ROUND_ROOT=$root"
  echo "ROUND_BASE=$diff_base"
  echo "ROUND_N=$round_n"
  echo "ROUND_LEDGER=$ledger"
  echo "ROUND_CR_LINES=$(jq .crLines "$ledger")"
  if [[ "$round_n" -gt 1 ]]; then
    echo "ROUND_PREVIOUS=$(jq -r '[.rounds[] | "\(.percent)%"] | join(", ")' "$ledger")"
  fi
  ;;

record)
  need_dir
  [[ -n "$id" ]] || { echo "review-round.sh record needs --id" >&2; exit 64; }
  [[ ! -s "$dir/items/$id.patch" ]] || die "item $id is already recorded; revert it before recording it again"
  prev=$(state lastTree)
  now=$(snapshot)
  [[ "$prev" != "$now" ]] || die "item $id changed nothing since the last record"
  git -C "$root" diff --binary --no-renames "$prev" "$now" > "$dir/items/$id.patch"
  set_state lastTree "$now"
  echo "ITEM=$id"
  git -C "$root" -c core.quotePath=false diff --name-only --no-renames "$prev" "$now" | sed 's/^/ITEM_FILE=/'
  ;;

revert)
  need_dir
  [[ -n "$id" ]] || { echo "review-round.sh revert needs --id" >&2; exit 64; }
  [[ -s "$dir/items/$id.patch" ]] || die "item $id has no recorded change to revert"
  git -C "$root" apply -R "$dir/items/$id.patch" 2>"$dir/revert.err" \
    || die "item $id no longer reverts cleanly: $(head -1 "$dir/revert.err"); a later item edited the same lines"
  rm -f "$dir/items/$id.patch"
  set_state lastTree "$(snapshot)"
  echo "REVERTED=$id"
  ;;

seed)
  need_dir
  [[ -n "$items" && -r "$items" ]] || { echo "review-round.sh seed needs a readable --items file" >&2; exit 64; }
  now=$(snapshot)
  [[ "$now" == "$(state lastTree)" ]] || die "the tree changed since the last record; record or revert that change before seeding the notes"
  lines="$dir/changed.tsv"
  changed_lines "$(state diffBase)" "$now" > "$lines"
  # Each site's anchor, worked out here rather than by the skill: a note sits on
  # the line above the one it is about, since revdiff draws it under its line.
  rows=$(jq -r '.items[] | .id as $id | .sites | to_entries[]
    | [$id, .key, .value.file, (.value.line // ""), (.value.side // "new")] | map(tostring) | join("\u001f")' "$items")
  anchors="$dir/anchors.tsv"; : > "$anchors"
  errors=()
  # A unit separator, not a tab: tabs are IFS whitespace, so an empty line field
  # would collapse into the next one.
  while IFS=$'\x1f' read -r iid k file line side; do
    [[ -n "$iid" ]] || continue
    if ! cut -f1 "$lines" | grep -qxF -- "$file"; then
      errors+=("#$iid $file: not changed in this review, so revdiff has nowhere to show the note")
      continue
    fi
    if [[ -z "$line" ]]; then
      printf '%s\t%s\t%s\tfile\t\n' "$iid" "$k" "$file" >> "$anchors"; continue
    fi
    if [[ "$side" == old ]]; then
      grep -qxF -- "${file}	-	${line}" "$lines" \
        || { errors+=("#$iid $file:$line (old side): not a removed line"); continue; }
      printf '%s\t%s\t%s\t-\t%s\n' "$iid" "$k" "$file" "$line" >> "$anchors"; continue
    fi
    at=$(( line > 1 ? line - 1 : 1 ))
    count=$(git -C "$root" cat-file -p "$now:$file" 2>/dev/null | awk 'END { print NR }')
    (( at <= ${count:-0} )) || { errors+=("#$iid $file:$line: past the end of the file ($count lines)"); continue; }
    marker=" "
    ! grep -qxF -- "${file}	+	${at}" "$lines" || marker="+"
    printf '%s\t%s\t%s\t%s\t%s\n' "$iid" "$k" "$file" "$marker" "$at" >> "$anchors"
  done <<<"$rows"
  if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo "ROUND_ERROR=$e"; done
    exit 65
  fi

  # The notes, in revdiff's markdown and as JSON to compare the returned set
  # against. The first site carries the reason; later ones point back to it.
  jq -n --slurpfile it "$items" --rawfile a "$anchors" '
    def status_tag: {applied:"", proposed:" · proposed", issue:" · proposed: file an issue", leave:" · proposed: leave it"}[.status];
    ($a | split("\n") | map(select(length > 0) | split("\t")
      | {id:(.[0]|tonumber), k:(.[1]|tonumber), file:.[2], marker:.[3], line:(if .[4] == "" then null else (.[4]|tonumber) end)})) as $anchors
    | [$it[0].items[] as $i
       | ($anchors | map(select(.id == $i.id)) | sort_by(.k)) as $mine
       | $mine | to_entries[]
       | .value as $s
       | ("#\($i.id) \($i.slug) · \($i.severity)" + ($i | status_tag)) as $head
       | {id:$i.id, file:$s.file, line:$s.line,
          side:(if $s.marker == "-" then "old" else "new" end), marker:$s.marker,
          body:($head + "\n" + (if .key == 0 then $i.reason
                 else "Part of #\($i.id); the reason is on its first note, at \($mine[0].file)\(if $mine[0].line then ":\($mine[0].line)" else "" end)." end))}]
  ' > "$dir/notes.json"
  jq -r '.[] | (if .marker == "file" then "## \(.file) (file-level)" else "## \(.file):\(.line) (\(.marker))" end)
         + "\n" + (.body | gsub("\n## "; "\n ## ")) + "\n"' "$dir/notes.json" > "$dir/notes.md"
  cp "$items" "$dir/items.json"

  {
    printf '# %s\n\n' "${title:-Review round}"
    cat <<'EOF'
Each row is one item. Every change and proposal in this review carries a note in
the diff headed with its number; an item with no "proposal" is already made in the
tree. To drop an item, delete its row (`e` opens this file in your editor) or
leave a note saying so. To change one, edit its note or annotate its row. A note
of your own becomes a new item. Quit with `q` when you're done.

| # | slug | severity | proposal | finding |
|---|---|---|---|---|
EOF
    jq -r '.items[] | "| \(.id) | \(.slug) | \(.severity) | \({applied:"", proposed:"proposed", issue:"file an issue", leave:"leave it"}[.status]) | \(.finding | gsub("\\|"; "\\|") | gsub("\n"; " ")) |"' "$items"
  } > "$root/$TABLE"
  grep '^| [0-9]' "$root/$TABLE" > "$dir/rows.seeded"
  echo "NOTES=$dir/notes.md"
  echo "TABLE=$root/$TABLE"
  echo "NOTE_COUNT=$(jq length "$dir/notes.json")"
  ;;

read)
  need_dir
  [[ -n "$returned" && -r "$returned" ]] || { echo "review-round.sh read needs the --returned file the review wrote" >&2; exit 64; }
  [[ -f "$dir/notes.json" ]] || die "nothing was seeded for this round"
  # A file the reviewer edited from inside revdiff is their own fix, read as
  # one rather than mistaken for a finding's change.
  now=$(snapshot)
  : > "$dir/user-edits.patch"
  if [[ "$now" != "$(state lastTree)" ]]; then
    git -C "$root" diff --binary --no-renames "$(state lastTree)" "$now" > "$dir/user-edits.patch"
  fi
  rows_now=""
  [[ -f "$root/$TABLE" ]] && rows_now=$(grep '^| *#*[0-9]' "$root/$TABLE" || true)
  table_lines=""
  [[ -f "$root/$TABLE" ]] && table_lines=$(cat "$root/$TABLE")

  # Map each returned line note on the new side to the CR head's numbering.
  mapped=$(jq -c '.[]' "$returned" | while IFS= read -r c; do
    f=$(jq -r '.file // ""' <<<"$c"); l=$(jq -r '.startLine // ""' <<<"$c"); sd=$(jq -r '.side // "new"' <<<"$c")
    cr="null"
    if [[ -n "$f" && -n "$l" && "$f" != "$TABLE" ]]; then
      if [[ "$sd" == old ]]; then cr="$l"; else cr=$(map_line "$f" "$l"); fi
    fi
    jq -c --argjson cr "$cr" '. + {crLine:$cr}' <<<"$c"
  done | jq -s '.')

  jq -n \
    --slurpfile items "$dir/items.json" --slurpfile seeded "$dir/notes.json" \
    --argjson ret "$mapped" --rawfile rows0 "$dir/rows.seeded" --arg rows "$rows_now" \
    --arg table "$table_lines" --arg tname "$TABLE" --arg edits "$dir/user-edits.patch" \
    --arg hasedits "$([[ -s "$dir/user-edits.patch" ]] && echo 1 || echo 0)" '
    def rowmap: split("\n") | map(select(test("^\\| *#?[0-9]")))
      | map({id:(capture("^\\| *#?(?<n>[0-9]+)").n|tonumber), row:.});
    def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def tag: (.body | split("\n")[0] | capture("^#(?<n>[0-9]+) ") | .n | tonumber)? // null;
    ($rows0 | rowmap) as $r0 | ($rows | rowmap) as $r1
    | ($table | split("\n")) as $tl
    | ($ret | map(select(.file != $tname))) as $codenotes
    | ($ret | map(select(.file == $tname))
        | map(. + {rowId: ((.startLine // 0) as $n | if $n > 0 then (($tl[$n-1] // "" | capture("^\\| *#?(?<n>[0-9]+)") | .n | tonumber)? // null) else null end)})) as $tnotes
    | ($seeded[0]) as $s
    | {items: [$items[0].items[] as $i
        | ($r0 | map(select(.id == $i.id)) | first | .row) as $was
        | ($r1 | map(select(.id == $i.id)) | first | .row) as $now
        | ($s | map(select(.id == $i.id))) as $mine
        | ($codenotes | map(select(tag == $i.id))) as $back
        | [$mine[] as $m
           | ($back | map(select(.file == $m.file and (.startLine // null) == $m.line)) | first) as $b
           | {file:$m.file, line:$m.line, side:$m.side, seeded:$m.body,
              returned:($b.body // null), crLine:($b.crLine // null),
              changed:($b != null and (($b.body | norm) != ($m.body | norm)))}] as $notes
        | ($tnotes | map(select(.rowId == $i.id)) | map(.body)) as $rownotes
        | {id:$i.id, slug:$i.slug, severity:$i.severity, status:$i.status,
           row:$now, rowNotes:$rownotes, notes:$notes,
           decision:(if $now == null then "drop"
                     elif ($notes | any(.changed)) or (($now|norm) != ($was|norm)) or ($rownotes | length > 0) then "change"
                     elif ($notes | any(.returned == null)) then "ask"
                     else "keep" end)}],
       added: [$codenotes[] | select(tag as $t | $t == null or ([$items[0].items[].id] | index($t)) == null)
               | {body, file, startLine, endLine, side, target, crLine}],
       tableNotes: [$tnotes[] | select(.rowId == null) | .body],
       userEdits: (if $hasedits == "1" then $edits else null end)}
  ' > "$dir/read.json"
  echo "ROUND_READ=$dir/read.json"
  jq -r '"KEEP=\([.items[]|select(.decision=="keep")|.id]|join(","))",
         "CHANGE=\([.items[]|select(.decision=="change")|.id]|join(","))",
         "DROP=\([.items[]|select(.decision=="drop")|.id]|join(","))",
         "ASK=\([.items[]|select(.decision=="ask")|.id]|join(","))",
         "ADDED=\(.added|length)",
         "USER_EDITS=\(if .userEdits then 1 else 0 end)"' "$dir/read.json"
  ;;

suggest)
  need_dir
  [[ -n "$id" && -n "$forge" ]] || { echo "review-round.sh suggest needs --id and --forge" >&2; exit 64; }
  [[ -s "$dir/items/$id.patch" ]] || die "item $id has no recorded change"
  not_one() { echo "SUGGESTIBLE=0"; echo "SUGGEST_REASON=$1"; exit 0; }
  # The item alone on top of the CR head, so its lines are numbered as the CR's
  # reader sees them rather than after the round's other edits.
  idx=$(anchor_tmpfile anchor-round-suggest idx)
  head_sha=$(state head)
  GIT_INDEX_FILE="$idx" git -C "$root" read-tree "$head_sha"
  if ! GIT_INDEX_FILE="$idx" git -C "$root" apply --cached "$dir/items/$id.patch" 2>/dev/null; then
    rm -f "$idx"; not_one "it depends on another item's edit to the same lines"
  fi
  hunks=$(GIT_INDEX_FILE="$idx" git -C "$root" -c core.quotePath=false diff --cached -U0 --no-color --no-renames "$head_sha")
  rm -f "$idx"
  files=$(grep -c '^+++ ' <<<"$hunks" || true)
  count=$(grep -c '^@@ ' <<<"$hunks" || true)
  [[ "$files" -eq 1 && "$count" -eq 1 ]] || not_one "it changes $count hunks across $files files; a suggestion replaces one run of lines"
  grep -q '^+++ /dev/null' <<<"$hunks" && not_one "it deletes a file"
  grep -q '^--- /dev/null' <<<"$hunks" && not_one "it adds a file"
  file=$(sed -n 's/^+++ b\///p' <<<"$hunks")
  read -r a b < <(sed -n 's/^@@ -\([0-9]*\)\(,\([0-9]*\)\)\{0,1\} .*/\1 \3/p' <<<"$hunks")
  b=${b:-1}
  new_text=$(awk '/^@@ /{h=1; next} h && /^\+/{print substr($0, 2)}' <<<"$hunks")
  if [[ "$b" -eq 0 ]]; then
    # Nothing replaced: anchor on the line the new ones follow, and carry it.
    [[ "$a" -gt 0 ]] || not_one "it inserts above the first line, which has no line to anchor to"
    start=$a; end=$a
    kept=$(git -C "$root" cat-file -p "$head_sha:$file" | sed -n "${a}p")
    new_text=$(printf '%s\n%s' "$kept" "$new_text")
  else
    start=$a; end=$((a + b - 1))
  fi
  case "$forge" in
    github) fence='```suggestion' ;;
    gitlab) fence="\`\`\`suggestion:-$((end - start))+0" ;;
    *) echo "review-round.sh: unknown forge: $forge" >&2; exit 64 ;;
  esac
  jq -cn --arg f "$file" --argjson s "$start" --argjson e "$end" --arg t "$new_text" --arg fence "$fence" \
    '{file:$f, startLine:$s, endLine:$e, side:"new", block:($fence + "\n" + $t + "\n```")}' \
    | sed 's/^/SUGGESTION=/'
  echo "SUGGESTIBLE=1"
  ;;

files)
  need_dir
  now=$(snapshot)
  git -C "$root" -c core.quotePath=false diff --name-only --no-renames "$(state startTree)" "$now" | sed 's/^/ROUND_FILE=/'
  ;;

finish)
  need_dir
  # What this round did, appended to the ledger before its state goes.
  now=$(snapshot)
  read -r files added removed < <(git -C "$root" diff --numstat --no-renames "$(state startTree)" "$now" \
    | awk '{ f++; a += $1; d += $2 } END { print f + 0, a + 0, d + 0 }')
  led=$(state ledger)
  [[ -f "$dir/items.json" ]] || echo '{"items":[]}' > "$dir/items.json"
  [[ -f "$dir/read.json" ]] || echo 'null' > "$dir/read.json"
  jq --argjson n "$(state n)" --argjson f "$files" --argjson a "$added" --argjson d "$removed" \
    --slurpfile items "$dir/items.json" --slurpfile read "$dir/read.json" '
    def count(s): [.[] | select(.status == s)] | length;
    def lines: if . == null then 0 else split("\n") | length end;
    ($items[0].items) as $it | ($read[0]) as $r
    | .rounds += [{
        n:$n,
        items:{applied:($it|count("applied")), proposed:($it|count("proposed")),
               issue:($it|count("issue")), leave:($it|count("leave"))},
        notes:(if $r == null then null else
          {kept:([$r.items[]|select(.decision=="keep")]|length),
           changed:([$r.items[]|select(.decision=="change")]|length),
           dropped:([$r.items[]|select(.decision=="drop")]|length),
           asked:([$r.items[]|select(.decision=="ask")]|length),
           added:($r.added|length),
           lines:(([$r.items[].notes[] | select(.changed) | .returned | lines] | add // 0)
                  + ([$r.items[].rowNotes[] | lines] | add // 0)
                  + ([$r.added[].body | lines] | add // 0))} end),
        edits:{files:$f, added:$a, removed:$d},
        percent:(if .crLines > 0 then ((($a + $d) * 1000 / .crLines) | round) / 10 else 0 end)}]
  ' "$led" > "$led.tmp"
  mv "$led.tmp" "$led"
  rm -f "$root/$TABLE"
  if [[ "$(state place)" == worktree ]]; then
    git -C "$(state repo)" worktree remove --force "$root" >/dev/null 2>&1 \
      || die "could not remove the review worktree at $root"
    rmdir "$(dirname "$root")" 2>/dev/null || true
  fi
  rm -rf "$dir"
  echo "FINISHED=1"
  jq -r '.rounds[-1] | "ROUND_N=\(.n)", "ROUND_PERCENT=\(.percent)", "ROUND_LINES=+\(.edits.added) -\(.edits.removed)"' "$led"
  echo "ROUND_LEDGER=$led"
  ;;

*) echo "review-round.sh: unknown command: $cmd" >&2; exit 64 ;;
esac
