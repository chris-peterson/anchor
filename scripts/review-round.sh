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
# A round is reviewed in two passes, each seeded on its own. The items pass
# diffs from the CR head, so the reviewer sees only the round's drafts and
# decides each item without the CR's own change around it. The whole pass diffs
# from the merge base, showing the CR as it will land with the kept fixes in it.
# Each pass gets its own table and notes; `finish` reads both passes' answers.
#
# Rounds are counted. The first `start` writes a ledger (ROUND_LEDGER) holding
# the size of the CR's own diff; each later `start` given that ledger is the next
# round, and each `finish` appends what its round did: the items by status, what
# the reviewer's notes said and how much they wrote, and how many lines the round
# changed, as a percent of the CR's diff. Re-review loops that keep finding things
# to polish show up as a percent that stops falling, and `sizes` draws the same
# numbers as bars, each round's over the CR's. `finish` also adds each item
# the reviewer dropped to the ledger's `rejected` list, which later rounds treat
# as settled (ROUND_REJECTED counts it). The ledger lives in the temp dir for as
# long as the session carries its path; nothing else reads it.
#
# Usage:
#   review-round.sh start   --base <sha> --head <sha> (--worktree | --in-place) [--ledger <file>] [--repo <path>]
#   review-round.sh record  --dir <round> --id <n>
#   review-round.sh revert  --dir <round> --id <n>
#   review-round.sh seed    --dir <round> --pass <items|whole> --items <items.json> [--title <heading, e.g. Review of <CR ref>: <CR title>>] [--cr-url <url>]
#   review-round.sh read    --dir <round> --returned <notes.returned.json>
#   review-round.sh suggest --dir <round> --id <n> --forge <github|gitlab>
#   review-round.sh files   --dir <round>
#   review-round.sh finish  --dir <round>
#   review-round.sh trend   --ledger <file>
#   review-round.sh sizes   --ledger <file>
#
# The items file `seed` reads, written by the skill:
#   {"items": [{"id": 1, "slug": "<kebab-case>", "severity": "critical|suggestion",
#               "status": "applied|proposed|issue|leave",
#               "finding": "<one line for the table>",
#               "reason": "<the note: why, and for a proposal what it would touch>",
#               "sites": [{"file": "<path>", "line": <n>, "side": "new|old"},
#                         {"file": "<path>"}]}]}
# A site's line is the first line of the edit (applied) or the line the change
# would go on (proposed), numbered in the tree as it now stands; an old-side line
# is numbered in the pass's base (the CR head, or the merge base). A site with no
# line is a note on the whole file. A line far from every change in the pass,
# including one in a file the pass doesn't change, goes in the table instead.
#
# Output is KEY=value lines on stdout. A failure prints ROUND_ERROR=<message>
# and exits non-zero rather than leaving a half-written round.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/item-review.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/item-review.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/size-stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/size-stack.sh"
# shellcheck source=lib/callout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/callout.sh"
# shellcheck source=lib/hints.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/hints.sh"
# shellcheck source=lib/verdict.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/verdict.sh"

TABLE="(context).md"

die() { echo "ROUND_ERROR=$*"; exit 65; }

cmd="${1:-}"
[[ -n "$cmd" ]] || { echo "usage: review-round.sh <start|record|revert|seed|read|suggest|files|finish|trend|sizes> ..." >&2; exit 64; }
shift

CTX_REPO=""
dir="" base="" head="" place="" id="" items="" returned="" forge="" title="" ledger="" cr_url="" pass=""
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
    --cr-url)    cr_url="${2:?--cr-url needs a URL}"; shift 2 ;;
    --ledger)    ledger="${2:?--ledger needs a file}"; shift 2 ;;
    --pass)      pass="${2:?--pass needs items or whole}"; shift 2 ;;
    *) echo "review-round.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

state() { jq -r --arg k "$1" '.[$k]' "$dir/round.json"; }
set_state() {
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$dir/round.json" > "$dir/round.json.tmp"
  mv "$dir/round.json.tmp" "$dir/round.json"
}

snapshot() { anchor_items_snapshot "$root" "$TABLE"; }

need_dir() {
  [[ -n "$dir" && -f "$dir/round.json" ]] || { echo "review-round.sh: --dir must name a round that start created" >&2; exit 64; }
  root=$(state root)
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

# Each finished round, newest first, then the CR as the first round found it, as
# size-stack rows.
size_rows() {
  jq -r '(.rounds | reverse[] | "round \(.n)\t\(.edits.files)\t\(.edits.added)\t\(.edits.removed)"),
    "original change\t\(.cr.files)\t\(.cr.added)\t\(.cr.removed)"' "$1"
}

case "$cmd" in

sizes)
  [[ -n "$ledger" && -f "$ledger" ]] || { echo "review-round.sh sizes needs the --ledger start printed" >&2; exit 64; }
  size_rows "$ledger" | anchor_size_stack
  ;;

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
    IFS=$'\t' read -r _ cr_files cr_added cr_removed \
      < <(git diff --numstat --no-renames "$diff_base" "$head" | anchor_size_row cr)
    jq -n --arg h "$(git rev-parse "$head")" \
      --argjson f "$cr_files" --argjson a "$cr_added" --argjson d "$cr_removed" \
      '{firstHead:$h, cr:{files:$f, added:$a, removed:$d}, crLines:($a + $d), rounds:[]}' > "$ledger"
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
  echo "ROUND_REJECTED=$(jq '.rejected // [] | length' "$ledger")"
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
  case "$pass" in
    items) from=$(state head) ;;
    whole) from=$(state diffBase) ;;
    *) echo "review-round.sh seed needs --pass items or --pass whole" >&2; exit 64 ;;
  esac
  now=$(snapshot)
  [[ "$now" == "$(state lastTree)" ]] || die "the tree changed since the last record; record or revert that change before seeding the notes"
  # The items pass's answers and items are what `finish` records as the round's
  # decisions, so the whole pass keeps them aside rather than overwriting them.
  if [[ "$pass" == whole && -f "$dir/read.json" && ! -f "$dir/read.items.json" ]]; then
    mv "$dir/read.json" "$dir/read.items.json"
    cp "$dir/items.json" "$dir/items.items.json"
  fi
  lines="$dir/changed.tsv"
  anchor_items_changed_lines "$root" "$from" "$now" > "$lines"
  rows=$(jq -r '.items[] | .id as $id | .sites | to_entries[]
    | [$id, .key, .value.file, (.value.line // ""), (.value.side // "new")] | map(tostring) | join("\u001f")' "$items")
  anchors="$dir/anchors.tsv"; : > "$anchors"
  errors=()
  # A unit separator, not a tab: tabs are IFS whitespace, so an empty line field
  # would collapse into the next one.
  while IFS=$'\x1f' read -r iid k file line side; do
    [[ -n "$iid" ]] || continue
    # Only an item's first site gets a note; the rest are named in it.
    if [[ -z "$line" && "$k" == 0 ]] && ! cut -f1 "$lines" | grep -xF -- "$file" >/dev/null; then
      errors+=("#$iid $file: not changed in this review, so a note on the whole file has nowhere to show; give it a line")
      continue
    fi
    if [[ -z "$line" ]]; then
      printf '%s\t%s\t%s\tfile\t\n' "$iid" "$k" "$file" >> "$anchors"; continue
    fi
    if ! at=$(anchor_items_anchor "$lines" "$root" "$now" "$file" "$line" "$side"); then
      errors+=("#$iid $file:$line: $at"); continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$iid" "$k" "$file" "$at" >> "$anchors"
  done <<<"$rows"
  if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo "ROUND_ERROR=$e"; done
    exit 65
  fi

  # The notes, in revdiff's markdown and as JSON to compare the returned set
  # against. One note per item, on its first site; the rest are named in it, since
  # a note at every site multiplies what the reviewer has to read.
  jq -n --slurpfile it "$items" --rawfile a "$anchors" '
    def status_tag: {applied:"", proposed:" · proposed", issue:" · proposed: file an issue", leave:" · proposed: leave it"}[.status];
    ($a | split("\n") | map(select(length > 0) | split("\t")
      | {id:(.[0]|tonumber), k:(.[1]|tonumber), file:.[2], marker:.[3], line:(if .[4] == "" then null else (.[4]|tonumber) end)})) as $anchors
    | [$it[0].items[] as $i
       | ($anchors | map(select(.id == $i.id)) | sort_by(.k) | first) as $s
       | select($s != null)
       | ("#\($i.id) \($i.slug) · \($i.severity)" + ($i | status_tag)) as $head
       | ($i.sites[1:] | map("\(.file)\(if .line then ":\(.line)" else "" end)")) as $also
       | {id:$i.id, file:$s.file, line:$s.line,
          side:(if $s.marker == "-" then "old" else "new" end), marker:$s.marker,
          body:($head + "\n" + $i.reason
                + (if ($also | length) > 0 then "\n\nAlso: " + ($also | join(", ")) + "." else "" end))}]
  ' > "$dir/notes.json"
  anchor_items_onto_hunks "$dir/notes.json" "$lines"
  # A note far from every change leaves the diff for the table (revdiff#405, see
  # anchor_items_onto_hunks). It still posts on its own line, numbered now while
  # the tree is the one the notes number.
  : > "$dir/far.jsonl"
  while IFS=$'\t' read -r iid f l; do
    [[ -n "$iid" ]] || continue
    jq -c --argjson cr "$(map_line "$f" "$l")" --arg x "$(git -C "$root" cat-file -p "$now:$f" \
          | awk -v n="$((l + 1))" 'NR >= n - 3 && NR <= n + 3 { printf "%s %4d  %s\n", (NR == n ? ">" : " "), NR, $0 }')" \
      --argjson id "$iid" --argjson l "$l" \
      '.[] | select(.far and .id == $id and .line == $l) | . + {crLine:$cr, excerpt:$x}' "$dir/notes.json" >> "$dir/far.jsonl"
  done < <(jq -r '.[] | select(.far) | "\(.id)\t\(.file)\t\(.line)"' "$dir/notes.json")
  jq '[.[] | select(.far | not)]' "$dir/notes.json" > "$dir/notes.json.tmp"
  mv "$dir/notes.json.tmp" "$dir/notes.json"
  anchor_items_notes_md "$dir/notes.json" > "$dir/notes.md"
  cp "$items" "$dir/items.json"

  # The table is often read cold, from a tab the reviewer left, so it opens by
  # saying what this review is, what quitting does, and where the change lives.
  n_items=$(jq '.items | length' "$items")
  n_applied=$(jq '[.items[] | select(.status == "applied")] | length' "$items")
  plural=$([[ "$n_items" == 1 ]] || echo s)
  if [[ "$pass" == items ]]; then
    about="\`/anchor:review\` read this change request and has $n_items item$plural for you: $n_applied drafted in the
tree, $(( n_items - n_applied )) without code. This diff holds only those drafts, from the change request's head,
so each item is decided on its own; the whole change comes next, with what you kept in it.
Each item is a note in the diff and a row in the table below."
    made="drafted"
  else
    about="This is the whole change request with the $n_items item$plural you kept from \`/anchor:review\` in it,
as it will land. Each kept item is a note in the diff and a row in the table below."
    made="already made"
  fi
  n=$(state n)
  [[ "$n" == 1 ]] || about+="
This is round $n: it looks only at what round $(( n - 1 ))'s commit changed."
  about+="
$(anchor_revdiff_box revdiff "")"
  if [[ "$pass" == items ]]; then
    accept="the agent takes out what you dropped and makes the changes you asked for, then opens the whole change with the fixes you kept"
  elif [[ "$(state place)" == in-place ]]; then
    accept="the agent makes the changes you kept or asked for, then opens the commit for you to approve"
  else
    accept="the agent drafts what you kept as suggestions and comments on the change request, and posts nothing until you approve the text"
  fi
  repo_url=$(cd "$root" && anchor_repo_web_url)
  where="\`$(basename "$(state repo)")\`"
  [[ -z "$repo_url" ]] || where="[$(basename "$(state repo)")]($repo_url)"
  if [[ "$(state place)" == in-place ]]; then
    branch=$(git -C "$root" branch --show-current)
    [[ -z "$branch" ]] || where+=" on \`$branch\`"
  fi
  [[ -z "$cr_url" ]] || where+=" · [change request]($cr_url)"
  sizes=$({ git -C "$root" diff --numstat --no-renames "$(state startTree)" "$now" | anchor_size_row "this round"
    size_rows "$(state ledger)"
  } | anchor_size_stack current)
  where+="
$sizes"
  jq -r '.items[] | "| \(.id) | \(.slug) | \(.severity) | \({applied:"", proposed:"proposed", issue:"file an issue", leave:"leave it"}[.status]) | \(.finding | gsub("\\|"; "\\|") | gsub("\n"; " ")) |"' "$items" \
    | anchor_items_table "${title:-Review of a change request}" "$about
$where
$(anchor_verdict_section "$accept" "stop the round, and nothing is committed or posted")
## How to answer
Answer on each item's note in the diff:
- **Keep it**: leave the note as it is, or answer \`ok\`, \`yes\`, \`apply\`, or 👍.
- **Drop it**: delete the note, or answer \`drop\`, \`ignore\`, \`leave\`, or \`no\`.
  A fix in the tree comes back out.
- **Change it**: write what you want instead.
- **Something new**: add a note of your own anywhere.
- **Finish**: choose in the Verdict section above, or leave a lone \`lgtm\` or
  \`stop\` on this file, off the rows. A word on an item's note or row answers
  that item.
An item with no proposal is $made in the tree.
This file, \`(context).md\`, is the guide to the review; it leaves the tree when
the review closes." \
      "| # | slug | severity | proposal | finding |" > "$root/$TABLE"
  if [[ -s "$dir/far.jsonl" ]]; then
    jq -rs '"## Notes away from the changes",
      "These concern lines no change is near, so they are here rather than in the diff. Answer each on its row above.",
      (.[] | "### \(.body | split("\n")[0]) at `\(.file):\(.line + 1)`", (.excerpt | rtrimstr("\n")),
             (.body | split("\n")[1:] | join("\n")))' "$dir/far.jsonl" >> "$root/$TABLE"
  fi
  cp "$root/$TABLE" "$dir/table.seeded"
  # The table sits in the user's checkout for the round, so git leaves it out of
  # `git status` and `git add -A`; finish removes it.
  exclude=$(git -C "$root" rev-parse --path-format=absolute --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  grep -qxF -- "/$TABLE" "$exclude" 2>/dev/null || printf '/%s\n' "$TABLE" >> "$exclude"
  echo "NOTES=$dir/notes.md"
  echo "TABLE=$root/$TABLE"
  echo "NOTE_COUNT=$(jq length "$dir/notes.json")"
  echo "ROUND_FROM=$from"
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

  # The table's ids are the item numbers, written with or without a leading #.
  jq -n \
    --slurpfile items "$dir/items.json" --slurpfile seeded "$dir/notes.json" --slurpfile far "$dir/far.jsonl" \
    --argjson ret "$mapped" --rawfile table0 "$dir/table.seeded" \
    --arg table "$table_lines" --arg tname "$TABLE" --arg edits "$dir/user-edits.patch" \
    --arg hasedits "$([[ -s "$dir/user-edits.patch" ]] && echo 1 || echo 0)" "$ANCHOR_ITEMS_JQ"'
    def num: if . == null then null else (ltrimstr("#") | tonumber? // null) end;
    def numrows: rowmap | map(.id |= num) | map(select(.id != null));
    def tag: (.body | split("\n")[0] | capture("^#(?<n>[0-9]+) ") | .n | tonumber)? // null;
    ($table0 | numrows) as $r0 | ($table | numrows) as $r1
    | ($table | split("\n")) as $tl
    | ($ret | map(select(.file != $tname))) as $codenotes
    | ($ret | map(select(.file == $tname) | . + {rowId: (rowof($tl) | num)})) as $tnotes
    | ($seeded[0]) as $s
    | {items: [$items[0].items[] as $i
        | ($r0 | map(select(.id == $i.id)) | first | .row) as $was
        | ($r1 | map(select(.id == $i.id)) | first | .row) as $now
        | ($s | map(select(.id == $i.id))) as $mine
        | [$mine[] as $m
           # The answer sits where the note was seeded: a note replaced by "drop"
           # has lost its #N, and still answers for this item.
           | ($codenotes | map(select(.file == $m.file and (.startLine // null) == $m.line
                                      and (tag == $i.id or tag == null))) | first) as $b
           | {file:$m.file, line:$m.line, side:$m.side, seeded:$m.body,
              returned:($b.body // null),
              crLine:(if $m.about == "file" then null else ($b.crLine // null) end),
              verdict:(if $b == null then "drop" else ($b.body | answer($m.body)) end)}
           | .changed = (.verdict == "change")] as $notes
        | ($far | map(select(.id == $i.id))
           | map({file, line, side, seeded:.body, returned:null, crLine, verdict:"same", changed:false, far:true})) as $farnotes
        | ($tnotes | map(select(.rowId == $i.id)) | map(.body)) as $rownotes
        | ($rownotes | map(answer(""))) as $rowsaid
        | {id:$i.id, slug:$i.slug, severity:$i.severity, status:$i.status,
           row:$now, rowNotes:[$rownotes[] | select(answer("") == "change")], notes:($notes + $farnotes),
           decision:(if ($notes | any(.verdict == "drop")) or ($rowsaid | any(. == "drop")) then "drop"
                     else decision($now;
                                   ($notes | any(.changed)) or rowedited($was; $now) or ($rowsaid | any(. == "change"));
                                   "keep") end)}],
       added: [$codenotes[] | . as $c
               | select(($s | any(.file == $c.file and .line == ($c.startLine // null))) | not)
               | select(tag as $t | $t == null or ([$items[0].items[].id] | index($t)) == null)
               | {body, file, startLine, endLine, side, target, crLine}],
       tableNotes: [$tnotes[] | select(.rowId == null) | .body],
       userEdits: (if $hasedits == "1" then $edits else null end)}
  ' > "$dir/read.json"
  echo "ROUND_READ=$dir/read.json"
  anchor_items_decisions "$dir/read.json" keep change drop
  jq -r '"ADDED=\(.added|length)",
         "USER_EDITS=\(if .userEdits then 1 else 0 end)"' "$dir/read.json"
  # The reviewer's edit stays in the tree as theirs, so the next record holds
  # only the agent's change and the next pass seeds over it.
  set_state lastTree "$now"
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
  # The items pass decides each item; a whole pass after it can still drop or
  # change one. With no whole pass, the one read is the items pass's.
  if [[ -f "$dir/read.items.json" ]]; then
    first_items="$dir/items.items.json" first_read="$dir/read.items.json"
    whole_items="$dir/items.json" whole_read="$dir/read.json"
  else
    first_items="$dir/items.json" first_read="$dir/read.json"
    whole_items=/dev/null whole_read=/dev/null
  fi
  jq --argjson n "$(state n)" --argjson f "$files" --argjson a "$added" --argjson d "$removed" \
    --slurpfile items "$first_items" --slurpfile read "$first_read" \
    --slurpfile witems "$whole_items" --slurpfile wread "$whole_read" '
    def count(s): [.[] | select(.status == s)] | length;
    def lines: if . == null then 0 else split("\n") | length end;
    def notelines: ([.items[].notes[] | select(.changed) | .returned | lines] | add // 0)
                   + ([.items[].rowNotes[] | lines] | add // 0)
                   + ([.added[].body | lines] | add // 0);
    ($items[0].items) as $it | ($read[0]) as $r | ($wread[0] // null) as $w
    | (($it + ($witems[0].items // [])) | unique_by(.id)) as $all
    | ([$w.items // [] | .[] | select(.decision == "drop") | .id]) as $wdrop
    | ([$w.items // [] | .[] | select(.decision == "change") | .id]) as $wchange
    | (if $r == null then null else
        [$r.items[] | .decision = (if (.id | IN($wdrop[])) then "drop"
                                   elif .decision == "keep" and (.id | IN($wchange[])) then "change"
                                   else .decision end)] end) as $final
    | .rounds += [{
        n:$n,
        items:{applied:($it|count("applied")), proposed:($it|count("proposed")),
               issue:($it|count("issue")), leave:($it|count("leave"))},
        notes:(if $r == null then null else
          {kept:([$final[]|select(.decision=="keep")]|length),
           changed:([$final[]|select(.decision=="change")]|length),
           dropped:([$final[]|select(.decision=="drop")]|length),
           asked:([$final[]|select(.decision=="ask")]|length),
           added:(($r.added|length) + ($w.added // [] | length)),
           lines:(($r | notelines) + (if $w == null then 0 else ($w | notelines) end))} end),
        edits:{files:$f, added:$a, removed:$d},
        percent:(if .crLines > 0 then ((($a + $d) * 1000 / .crLines) | round) / 10 else 0 end)}]
    | .rejected = ((.rejected // []) + (if $r == null then [] else
        [($final[] | select(.decision == "drop") | .id), $wdrop[]] | unique
        | map(. as $id | $all[] | select(.id == $id) | {slug, severity, finding, round:$n}) end))
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
