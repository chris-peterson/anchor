#!/usr/bin/env bash
# Functional test for scripts/review-round.sh: a round's tree, its per-item
# patches, the revdiff notes and table it seeds, and how it reads the reviewer's
# notes back. Drives the script against throwaway repos. Requires jq.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
round="$here/../scripts/review-round.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-round-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false
seq 1 10 | sed 's/^/line /' > "$repo/a.txt"
printf 'keep\n' > "$repo/b.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m base
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch --quiet -c feature
sed -i.bak 's/^line 5$/line five/' "$repo/a.txt"; rm -f "$repo/a.txt.bak"
printf 'new\n' > "$repo/c.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m feature
head=$(git -C "$repo" rev-parse HEAD)

round_cmd() { bash "$round" "$@"; }

# ============================ start ======================================

printf 'stray\n' >> "$repo/b.txt"
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place || true)
[[ "$(val ROUND_ERROR "$o")" == *"uncommitted changes"* ]] || fail "a dirty checkout should be refused: $o"
git -C "$repo" checkout --quiet -- b.txt
ok "start: an in-place round refuses a checkout with uncommitted changes"

git -C "$repo" switch --quiet main
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place || true)
[[ "$(val ROUND_ERROR "$o")" == *"not the CR head"* ]] || fail "a checkout off the head should be refused: $o"
git -C "$repo" switch --quiet feature
ok "start: an in-place round refuses a checkout that isn't on the CR head"

o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place)
dir=$(val ROUND_DIR "$o"); root=$(val ROUND_ROOT "$o")
[[ "$root" == "$(git -C "$repo" rev-parse --show-toplevel)" ]] || fail "in-place root: $root"
[[ "$(val ROUND_BASE "$o")" == "$base" ]] || fail "ROUND_BASE should be the merge base: $o"
ok "start: an in-place round edits the checkout, diffing from the merge base"

# ============================ record / seed ===============================

# item 1 replaces line 2; item 2 inserts after line 8
sed -i.bak 's/^line 2$/line TWO/' "$root/a.txt"; rm -f "$root/a.txt.bak"
o=$(round_cmd record --dir "$dir" --id 1)
[[ "$(val ITEM_FILE "$o")" == a.txt ]] || fail "record 1 files: $o"
sed -i.bak 's/^line 8$/line 8\
inserted/' "$root/a.txt"; rm -f "$root/a.txt.bak"
round_cmd record --dir "$dir" --id 2 >/dev/null
o=$(round_cmd record --dir "$dir" --id 3 || true)
[[ "$(val ROUND_ERROR "$o")" == *"changed nothing"* ]] || fail "an empty record should be refused: $o"
[[ -z "$(git -C "$repo" diff --cached --name-only)" ]] || fail "recording must not stage anything"
ok "record: one patch per item, nothing staged, an empty item refused"

items="$work/items.json"
cat > "$items" <<'EOF'
{"items": [
  {"id": 1, "slug": "upper-two", "severity": "nit", "status": "applied",
   "finding": "Line 2 reads | better upper", "reason": "Matches the heading style.",
   "sites": [{"file": "a.txt", "line": 2}]},
  {"id": 2, "slug": "insert-after-eight", "severity": "consider", "status": "applied",
   "finding": "A line is missing after 8", "reason": "The list skips a step.",
   "sites": [{"file": "a.txt", "line": 9}, {"file": "c.txt"}]},
  {"id": 3, "slug": "rename-ten", "severity": "important", "status": "proposed",
   "finding": "Line 10 should be renamed", "reason": "Callers read it by name; renaming touches two files.",
   "sites": [{"file": "a.txt", "line": 11}]}
]}
EOF
o=$(round_cmd seed --dir "$dir" --items "$items" --title "Review of #7")
notes=$(val NOTES "$o")
[[ "$(val NOTE_COUNT "$o")" == 4 ]] || fail "4 notes expected: $o"
grep -qx '## a.txt:1 ( )' "$notes" || fail "item 1 sits above line 2, on unchanged line 1: $(cat "$notes")"
grep -qx '## a.txt:8 ( )' "$notes" || fail "item 2 sits above its insertion: $(cat "$notes")"
grep -qx '## c.txt (file-level)' "$notes" || fail "a site with no line is a file note"
grep -qx '## a.txt:10 ( )' "$notes" || fail "item 3 sits above line 11: $(cat "$notes")"
grep -qx '#3 rename-ten · important · proposed' "$notes" || fail "a proposal's header names its status"
grep -qx '#1 upper-two · nit' "$notes" || fail "an applied item's header carries no status"
grep -q '^Part of #2; the reason is on its first note, at a.txt:8' "$notes" || fail "a later site points back: $(cat "$notes")"
table="$root/.review.md"
grep -qx '| 1 | upper-two | nit |  | Line 2 reads \\| better upper |' "$table" || fail "table row 1: $(cat "$table")"
grep -qx '| 3 | rename-ten | important | proposed | Line 10 should be renamed |' "$table" || fail "table row 3"
ok "seed: notes sit above their lines with the right marker, and the table lists every item"

bad="$work/bad.json"
jq '.items[0].sites = [{"file": "b.txt", "line": 1}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"b.txt: not changed in this review"* ]] || fail "a site on an unchanged file should be refused: $o"
jq '.items[0].sites = [{"file": "a.txt", "line": 99}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"past the end"* ]] || fail "a site past the end should be refused: $o"
round_cmd seed --dir "$dir" --items "$items" >/dev/null
ok "seed: a note revdiff would drop is refused before the review opens"

# ============================ read =======================================

# The reviewer keeps item 1, edits item 2's note, deletes item 3's note but
# keeps its row, and adds a note of their own.
returned="$work/notes.returned.json"
jq '[.[] | {body, target:(if .line then "line" else "file" end), file, startLine:.line, endLine:.line, side}]
    | map(if (.body | startswith("#2")) and .file == "a.txt" then .body += "\nUse a constant instead." else . end)
    | map(select(.body | startswith("#3") | not))
    + [{body:"why not five?", target:"line", file:"a.txt", startLine:6, endLine:6, side:"new"}]' \
  "$dir/notes.json" > "$returned"
o=$(round_cmd read --dir "$dir" --returned "$returned")
[[ "$(val KEEP "$o")" == 1 && "$(val CHANGE "$o")" == 2 && "$(val ASK "$o")" == 3 && "$(val ADDED "$o")" == 1 ]] \
  || fail "read decisions: $o"
r=$(val ROUND_READ "$o")
# line 6 in the round's tree is line 6 at the head (item 1 replaced a line, no shift)
[[ "$(jq '.added[0].crLine' "$r")" == 6 ]] || fail "added note crLine: $(jq -c '.added' "$r")"
ok "read: kept, changed, a deleted note with its row asks, and a note of your own is new"

# Deleting a row drops the item; a note on a row changes it.
grep -v '^| 1 ' "$table" > "$table.tmp"; mv "$table.tmp" "$table"
row3=$(grep -n '^| 3 ' "$table" | cut -d: -f1)
jq --argjson n "$row3" '. + [{body:"make this a follow-up", target:"line", file:".review.md", startLine:$n, endLine:$n, side:"new"}]' \
  "$returned" > "$returned.2"
o=$(round_cmd read --dir "$dir" --returned "$returned.2")
[[ "$(val DROP "$o")" == 1 ]] || fail "a deleted row drops: $o"
[[ ",$(val CHANGE "$o")," == *",3,"* ]] || fail "a note on a row changes it: $o"
[[ "$(jq -r '.items[] | select(.id==3) | .rowNotes[0]' "$(val ROUND_READ "$o")")" == "make this a follow-up" ]] || fail "row note text"
ok "read: a deleted row drops its item, and a note on a row changes it"

# An edit the reviewer made from inside revdiff comes back as theirs.
printf 'reviewer\n' >> "$root/c.txt"
o=$(round_cmd read --dir "$dir" --returned "$returned")
[[ "$(val USER_EDITS "$o")" == 1 ]] || fail "a reviewer's own edit should be reported: $o"
grep -q '^+reviewer' "$(jq -r .userEdits "$(val ROUND_READ "$o")")" || fail "user-edits patch"
git -C "$repo" checkout --quiet -- c.txt
ok "read: a file the reviewer edited in the review comes back as their edit"

# ============================ revert / files / finish ====================

round_cmd revert --dir "$dir" --id 1 >/dev/null
grep -qx 'line 2' "$root/a.txt" || fail "revert 1 should restore line 2"
grep -qx 'inserted' "$root/a.txt" || fail "revert 1 should leave item 2"
o=$(round_cmd files --dir "$dir")
[[ "$(val ROUND_FILE "$o")" == a.txt ]] || fail "files: $o"
ok "revert: one item comes back out and the others stay"

o=$(round_cmd finish --dir "$dir")
[[ ! -e "$table" && ! -d "$dir" ]] || fail "finish should remove the table and the round"
ok "finish: the table and the round's state are gone"

# The CR changes 3 lines (line 5 replaced, c.txt added); the round kept one
# inserted line, so it changed a third of the CR.
ledger=$(val ROUND_LEDGER "$o")
[[ "$(val ROUND_N "$o")" == 1 && "$(val ROUND_PERCENT "$o")" == 33.3 && "$(val ROUND_LINES "$o")" == "+1 -0" ]] \
  || fail "round 1 summary: $o"
[[ "$(jq '.rounds[0].notes | "\(.dropped) \(.added) \(.lines)"' -r "$ledger")" == "1 1 4" ]] \
  || fail "round 1 notes: $(jq -c '.rounds[0].notes' "$ledger")"
[[ "$(jq '.rounds[0].items | "\(.applied) \(.proposed)"' -r "$ledger")" == "2 1" ]] || fail "round 1 items"
ok "finish: the round's size, notes, and percent of the CR land in the ledger"

git -C "$repo" checkout --quiet -- a.txt
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place --ledger "$ledger")
[[ "$(val ROUND_N "$o")" == 2 && "$(val ROUND_PREVIOUS "$o")" == "33.3%" ]] || fail "round 2 start: $o"
o=$(round_cmd finish --dir "$(val ROUND_DIR "$o")")
[[ "$(val ROUND_PERCENT "$o")" == 0 ]] || fail "an empty round changes 0%: $o"
t=$(round_cmd trend --ledger "$ledger")
[[ "$(grep -c '^| [0-9]' <<<"$t")" == 2 ]] || fail "trend should have a row per round: $t"
grep -q '^| 2 | 0 applied, 0 proposed | not read | +0 −0 in 0 files | 0% |$' <<<"$t" || fail "round 2 row: $t"
ok "start: a ledger makes the next round round 2, and trend tabulates both"

# ============================ someone else's CR ==========================

o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --worktree)
dir=$(val ROUND_DIR "$o"); root=$(val ROUND_ROOT "$o")
[[ "$root" != "$repo" && -f "$root/a.txt" ]] || fail "worktree root: $root"
# item 1 inserts two lines after line 3; item 2 replaces line 9 and line 10
sed -i.bak 's/^line 3$/line 3\
x\
y/' "$root/a.txt"; rm -f "$root/a.txt.bak"
round_cmd record --dir "$dir" --id 1 >/dev/null
sed -i.bak -e 's/^line 9$/line nine/' -e 's/^line 10$/line ten/' "$root/a.txt"; rm -f "$root/a.txt.bak"
round_cmd record --dir "$dir" --id 2 >/dev/null
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "a worktree round must leave the checkout alone"

o=$(round_cmd suggest --dir "$dir" --id 2 --forge github)
s=$(val SUGGESTION "$o")
[[ "$(jq -r '"\(.file) \(.startLine)-\(.endLine)"' <<<"$s")" == "a.txt 9-10" ]] || fail "suggestion is numbered at the CR head: $s"
[[ "$(jq -r .block <<<"$s")" == $'```suggestion\nline nine\nline ten\n```' ]] || fail "github block: $s"
o=$(round_cmd suggest --dir "$dir" --id 2 --forge gitlab)
[[ "$(val SUGGESTION "$o" | jq -r .block | head -1)" == '```suggestion:-1+0' ]] || fail "gitlab block: $o"
o=$(round_cmd suggest --dir "$dir" --id 1 --forge github)
s=$(val SUGGESTION "$o")
[[ "$(jq -r '"\(.startLine)-\(.endLine)"' <<<"$s")" == "3-3" ]] || fail "an insertion anchors on the line before it: $s"
[[ "$(jq -r .block <<<"$s")" == $'```suggestion\nline 3\nx\ny\n```' ]] || fail "insertion block carries that line: $s"
ok "suggest: a one-hunk fix becomes a suggestion numbered at the CR head, per forge"

printf 'more\n' >> "$root/b.txt"; sed -i.bak 's/^line 1$/line one/' "$root/a.txt"; rm -f "$root/a.txt.bak"
round_cmd record --dir "$dir" --id 3 >/dev/null
o=$(round_cmd suggest --dir "$dir" --id 3 --forge github)
[[ "$(val SUGGESTIBLE "$o")" == 0 ]] || fail "a two-file fix is not a suggestion: $o"
ok "suggest: a fix across files stays a thread"

# a proposal noted above worktree line 8 sits on line 7, which is head line 5
# once item 1's two inserted lines are taken out; a note on an inserted line
# has no head line at all
cat > "$items" <<'EOF'
{"items": [{"id": 4, "slug": "p", "severity": "consider", "status": "proposed",
  "finding": "f", "reason": "r", "sites": [{"file": "a.txt", "line": 8}, {"file": "a.txt", "line": 6}]}]}
EOF
round_cmd seed --dir "$dir" --items "$items" >/dev/null
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$dir/notes.json" > "$returned"
r=$(val ROUND_READ "$(round_cmd read --dir "$dir" --returned "$returned")")
[[ "$(jq -r '.items[0].notes | map("\(.line) \(.crLine)") | join(",")' "$r")" == "7 5,5 null" ]] \
  || fail "worktree line 7 is head line 5, and inserted line 5 has none: $(jq -c .items[0].notes "$r")"
ok "read: a note's line maps back to the CR head past the round's own insertions"

round_cmd finish --dir "$dir" >/dev/null
[[ ! -e "$root" ]] || fail "finish should remove the worktree"
git -C "$repo" worktree list | grep -q anchor-review-tree && fail "the worktree is still registered"
ok "finish: the worktree is removed and unregistered"

echo "# all checks passed"
