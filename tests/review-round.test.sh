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
o=$(round_cmd seed --dir "$dir" --items "$items" --title "Review of #7: Tidy the list" --cr-url "https://example.com/pr/7")
notes=$(val NOTES "$o")
[[ "$(val NOTE_COUNT "$o")" == 3 ]] || fail "one note per item: $o"
# Each note sits above its site; a note on an unchanged line within a few lines
# of a change stays there, since ] brings it on screen (revdiff#405).
grep -qx '## a.txt:1 ( )' "$notes" || fail "item 1 sits above line 2, on unchanged line 1: $(cat "$notes")"
grep -qx '## a.txt:8 ( )' "$notes" || fail "item 2 sits above its insertion: $(cat "$notes")"
grep -qx '## a.txt:10 ( )' "$notes" || fail "item 3 sits above line 11, near the insertion: $(cat "$notes")"
! grep -q '^↪' "$notes" || fail "a note near a change is not moved: $(cat "$notes")"
grep -qx '#3 rename-ten · important · proposed' "$notes" || fail "a proposal's header names its status"
grep -qx '#1 upper-two · nit' "$notes" || fail "an applied item's header carries no status"
grep -qx 'Also: c.txt.' "$notes" || fail "an item's other sites are named in its one note: $(cat "$notes")"
! grep -q '^## c.txt' "$notes" || fail "a later site gets no note of its own: $(cat "$notes")"
table="$root/(context).md"
grep -qx '| 1 | upper-two | nit |  | Line 2 reads \\| better upper |' "$table" || fail "table row 1: $(cat "$table")"
grep -qx '| 3 | rename-ten | important | proposed | Line 10 should be renamed |' "$table" || fail "table row 3"
[[ -z "$(git -C "$root" status --porcelain --untracked-files=all -- '(context).md')" ]] || fail "git leaves the table out of status"
ok "seed: notes sit above their lines with the right marker, and the table lists every item, out of git's sight"

grep -qx '# Review of #7: Tidy the list' "$table" || fail "a first round is the review, not round 1: $(head -1 "$table")"
! grep -qi 'round 1' "$table" || fail "a first round is never numbered: $(cat "$table")"
grep -q 'has 3 items for you: 2 already made' "$table" || fail "the table says what the review found: $(cat "$table")"
grep -q 'opens the commit for you to approve' "$table" || fail "an in-place round says quitting leads to a commit"
grep -q "on \`$(git -C "$root" branch --show-current)\` · \[change request\](https://example.com/pr/7)" "$table" \
  || fail "the table names the branch and links the CR: $(cat "$table")"
grep -qF "This file, \`(context).md\`, is the guide to the review" "$table" || fail "the table says what it is"
# shellcheck disable=SC2016
[ "$(sed -n '/^```diff$/,/^```$/{/^ /p;}' "$table")" = ' 2 files' ] \
  || fail "a first round draws the CR alone, with no row for its own fixes: $(cat "$table")"
grep -q '^+█' "$table" || fail "a first round colours the CR's bars: $(cat "$table")"
! grep -q '░' "$table" || fail "a first round draws nothing muted: $(cat "$table")"
ok "seed: the table opens by saying what the review is, what quitting does, and where the change lives"

bad="$work/bad.json"
jq '.items[0].sites = [{"file": "b.txt", "line": 1}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"b.txt: not changed in this review"* ]] || fail "a site on an unchanged file should be refused: $o"
jq '.items[0].sites = [{"file": "a.txt", "line": 99}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"a.txt:99: not a line of the file"* ]] || fail "a site past the end should be refused: $o"
round_cmd seed --dir "$dir" --items "$items" >/dev/null
ok "seed: a note revdiff would drop is refused before the review opens"

# ============================ read =======================================

# The reviewer keeps item 1, edits item 2's note, deletes item 3's note, and
# adds a note of their own.
returned="$work/notes.returned.json"
jq '[.[] | {body, target:(if .line then "line" else "file" end), file, startLine:.line, endLine:.line, side}]
    | map(if (.body | startswith("#2")) and .file == "a.txt" then .body += "\nUse a constant instead." else . end)
    | map(select(.body | startswith("#3") | not))
    + [{body:"why not five?", target:"line", file:"a.txt", startLine:6, endLine:6, side:"new"}]' \
  "$dir/notes.json" > "$returned"
o=$(round_cmd read --dir "$dir" --returned "$returned")
[[ "$(val KEEP "$o")" == 1 && "$(val CHANGE "$o")" == 2 && "$(val DROP "$o")" == 3 && "$(val ADDED "$o")" == 1 ]] \
  || fail "read decisions: $o"
r=$(val ROUND_READ "$o")
# line 6 in the round's tree is line 6 at the head (item 1 replaced a line, no shift)
[[ "$(jq '.added[0].crLine' "$r")" == 6 ]] || fail "added note crLine: $(jq -c '.added' "$r")"
ok "read: kept, changed, a deleted note drops its item, and a note of your own is new"

# A note's text replaced with a word is the answer: a drop word drops, a yes keeps,
# and either way it is not read as a note of the reviewer's own.
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]
    | map(if (.body | startswith("#1")) then .body = "drop"
          elif (.body | startswith("#2")) then .body = ":thumbsup:"
          else .body += "\n\ud83d\udc4d" end)' "$dir/notes.json" > "$returned.words"
o=$(round_cmd read --dir "$dir" --returned "$returned.words")
[[ "$(val DROP "$o")" == 1 && "$(val KEEP "$o")" == "2,3" && "$(val ADDED "$o")" == 0 ]] \
  || fail "answer words: $o"
ok "read: a note answered with drop drops its item, and one answered with a yes keeps it"

# Deleting a row drops the item; a note on a row changes it.
grep -v '^| 1 ' "$table" > "$table.tmp"; mv "$table.tmp" "$table"
row3=$(grep -n '^| 3 ' "$table" | cut -d: -f1)
jq --argjson n "$row3" '. + [{body:"make this a follow-up", target:"line", file:"(context).md", startLine:$n, endLine:$n, side:"new"},
                              {body:"fewer rounds, please", target:"line", file:"(context).md", startLine:1, endLine:1, side:"new"}]' \
  <(jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$dir/notes.json") > "$returned.2"
o=$(round_cmd read --dir "$dir" --returned "$returned.2")
[[ "$(val DROP "$o")" == 1 ]] || fail "a deleted row drops: $o"
[[ ",$(val CHANGE "$o")," == *",3,"* ]] || fail "a note on a row changes it: $o"
[[ "$(jq -r '.items[] | select(.id==3) | .rowNotes[0]' "$(val ROUND_READ "$o")")" == "make this a follow-up" ]] || fail "row note text"
[[ "$(jq -r '.tableNotes[0]' "$(val ROUND_READ "$o")")" == "fewer rounds, please" ]] || fail "a note off the rows: $(jq -c .tableNotes "$(val ROUND_READ "$o")")"
ok "read: a deleted row drops its item, a note on a row changes it, and a note off the rows is kept"

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
# item 1's row and item 3's note were deleted; item 2's edited note runs to
# header, reason, blank, Also, and the added line
[[ "$(jq '.rounds[0].notes | "\(.dropped) \(.added) \(.lines)"' -r "$ledger")" == "2 1 6" ]] \
  || fail "round 1 notes: $(jq -c '.rounds[0].notes' "$ledger")"
[[ "$(jq -r '.rejected | map(.slug) | join(",")' "$ledger")" == "upper-two,rename-ten" ]] \
  || fail "a dropped item is remembered as rejected: $(jq -c '.rejected' "$ledger")"
[[ "$(jq '.rounds[0].items | "\(.applied) \(.proposed)"' -r "$ledger")" == "2 1" ]] || fail "round 1 items"
ok "finish: the round's size, notes, and percent of the CR land in the ledger"

git -C "$repo" checkout --quiet -- a.txt
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place --ledger "$ledger")
[[ "$(val ROUND_N "$o")" == 2 && "$(val ROUND_PREVIOUS "$o")" == "33.3%" ]] || fail "round 2 start: $o"
[[ "$(val ROUND_REJECTED "$o")" == 2 ]] || fail "round 2 starts knowing what round 1 rejected: $o"
o=$(round_cmd finish --dir "$(val ROUND_DIR "$o")")
[[ "$(val ROUND_PERCENT "$o")" == 0 ]] || fail "an empty round changes 0%: $o"
t=$(round_cmd trend --ledger "$ledger")
[[ "$(grep -c '^| [0-9]' <<<"$t")" == 2 ]] || fail "trend should have a row per round: $t"
grep -q '^| 2 | 0 applied, 0 proposed | not read | +0 −0 in 0 files | 0% |$' <<<"$t" || fail "round 2 row: $t"
t=$(round_cmd sizes --ledger "$ledger")
[[ "$(grep '^ [a-z]' <<<"$t")" == "$(printf '%s\n' ' round 2 · no changes' ' round 1 · 1 file' ' original change · 2 files')" ]] \
  || fail "sizes stacks each round, newest first, over the CR: $t"
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

wt_items="$work/wt-items.json"
jq -n '{items:[{id:1, slug:"two-lines", severity:"nit", status:"applied", finding:"Adds x and y",
  reason:"The list needs them.", sites:[{file:"a.txt", line:4}]}]}' > "$wt_items"
round_cmd seed --dir "$dir" --items "$wt_items" --title "Review of #9: Theirs" >/dev/null
grep -q 'posts nothing until you approve' "$root/(context).md" \
  || fail "a round on someone else's CR says quitting drafts posts: $(cat "$root/(context).md")"
grep -q '^│ When you quit with q,' "$root/(context).md" \
  || fail "what quitting does is outlined: $(cat "$root/(context).md")"
grep -q 'has 1 item for you' "$root/(context).md" || fail "one item is singular"
ok "seed: a round on someone else's CR says what quitting drafts, and posts nothing unapproved"

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
  "finding": "f", "reason": "r", "sites": [{"file": "a.txt", "line": 8}]},
  {"id": 5, "slug": "q", "severity": "consider", "status": "proposed",
  "finding": "g", "reason": "s", "sites": [{"file": "a.txt", "line": 6}]}]}
EOF
round_cmd seed --dir "$dir" --items "$items" >/dev/null
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$dir/notes.json" > "$returned"
r=$(val ROUND_READ "$(round_cmd read --dir "$dir" --returned "$returned")")
[[ "$(jq -r '[.items[].notes[] | "\(.line) \(.crLine)"] | join(",")' "$r")" == "7 5,5 null" ]] \
  || fail "worktree line 7 is head line 5, and inserted line 5 has none: $(jq -c '[.items[].notes]' "$r")"
ok "read: a note's line maps back to the CR head past the round's own insertions"

round_cmd finish --dir "$dir" >/dev/null
[[ ! -e "$root" ]] || fail "finish should remove the worktree"
git -C "$repo" worktree list | grep -q anchor-review-tree && fail "the worktree is still registered"
ok "finish: the worktree is removed and unregistered"

# revdiff#405: ] steps hunk to hunk. A whole-file note moves onto its file's
# change; a note far from every change goes to the table with an excerpt, is
# answered on its row, and still posts on its own line.
far="$work/far"
git init --quiet -b main "$far"
git -C "$far" config user.email t@example.com; git -C "$far" config user.name T; git -C "$far" config commit.gpgsign false
seq 1 40 | sed 's/^/fn_/' > "$far/app.sh"; printf 'unchanged\n' > "$far/other.sh"
git -C "$far" add -A; git -C "$far" commit --quiet -m base
f0=$(git -C "$far" rev-parse HEAD)
sed -i.bak -e 's/^fn_5$/fn_5_renamed/' -e 's/^fn_30$/fn_30_renamed/' "$far/app.sh"; rm -f "$far/app.sh.bak"
printf 'changed\n' > "$far/other.sh"
git -C "$far" commit --quiet -am change
f1=$(git -C "$far" rev-parse HEAD)
o=$(round_cmd start --repo "$far" --base "$f0" --head "$f1" --in-place); fdir=$(val ROUND_DIR "$o")
jq -n '{items:[
  {id:1, slug:"near", severity:"suggestion", status:"proposed", finding:"f", reason:"About line 7.", sites:[{file:"app.sh", line:7}]},
  {id:2, slug:"far", severity:"suggestion", status:"proposed", finding:"g", reason:"About line 18.", sites:[{file:"app.sh", line:18}]},
  {id:3, slug:"whole", severity:"suggestion", status:"proposed", finding:"h", reason:"About other.sh.", sites:[{file:"other.sh"}]}]}' > "$work/far-items.json"
o=$(round_cmd seed --dir "$fdir" --items "$work/far-items.json")
fnotes=$(val NOTES "$o"); ftable="$far/(context).md"
grep -qx '## app.sh:6 ( )' "$fnotes" || fail "a note near a change stays put: $(cat "$fnotes")"
grep -qx '## other.sh:1 (+)' "$fnotes" || fail "a whole-file note moves onto its file's change: $(cat "$fnotes")"
grep -qx '↪ about the whole file' "$fnotes" || fail "the moved note says what it concerns"
! grep -q '^#2 ' "$fnotes" || fail "a note far from every change is not in the diff: $(cat "$fnotes")"
grep -qF "### #2 far · suggestion · proposed at \`app.sh:18\`" "$ftable" || fail "the far note is in the table: $(cat "$ftable")"
grep -qx '>   18  fn_18' "$ftable" || fail "the far note quotes the line it concerns: $(cat "$ftable")"
row2=$(grep -n '^| 2 ' "$ftable" | cut -d: -f1)
jq --argjson n "$row2" '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]
    + [{body:"drop", target:"line", file:"(context).md", startLine:$n, endLine:$n, side:"new"}]' "$fdir/notes.json" > "$work/far-returned.json"
o=$(round_cmd read --dir "$fdir" --returned "$work/far-returned.json")
[[ "$(val DROP "$o")" == 2 && "$(val KEEP "$o")" == "1,3" ]] || fail "a far item is answered on its row: $o"
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$fdir/notes.json" > "$work/far-kept.json"
o=$(round_cmd read --dir "$fdir" --returned "$work/far-kept.json")
[[ "$(val KEEP "$o")" == "1,2,3" ]] || fail "a far item left alone is kept, not read as a deleted note: $o"
[[ "$(jq '.items[] | select(.id == 2) | .notes[0].crLine' "$(val ROUND_READ "$o")")" == 17 ]] \
  || fail "a far item still posts on its own line: $(jq -c '.items[1].notes' "$(val ROUND_READ "$o")")"
round_cmd finish --dir "$fdir" >/dev/null
ok "revdiff#405: a whole-file note moves onto its change, a far note goes to the table and is answered on its row"

# git ends a diff header with a tab when the path has a space; the tab is not
# part of the path.
sp="$work/spaced"
git init --quiet -b main "$sp"
git -C "$sp" config user.email t@example.com; git -C "$sp" config user.name T; git -C "$sp" config commit.gpgsign false
printf 'one\ntwo\nthree\n' > "$sp/x y.txt"
git -C "$sp" add -A; git -C "$sp" commit --quiet -m base
s0=$(git -C "$sp" rev-parse HEAD)
printf 'ONE\nTWO\nTHREE\n' > "$sp/x y.txt"
git -C "$sp" commit --quiet -am change
s1=$(git -C "$sp" rev-parse HEAD)
o=$(round_cmd start --repo "$sp" --base "$s0" --head "$s1" --in-place); sdir=$(val ROUND_DIR "$o")
jq -n '{items:[{id:1, slug:"case", severity:"nit", status:"applied", finding:"f", reason:"r", sites:[{file:"x y.txt", line:2}]}]}' > "$work/spaced-items.json"
o=$(round_cmd seed --dir "$sdir" --items "$work/spaced-items.json")
grep -qx '## x y.txt:1 (+)' "$(val NOTES "$o")" || fail "a spaced path's changed line keeps its marker: $(cat "$(val NOTES "$o")")"
round_cmd finish --dir "$sdir" >/dev/null
ok "a path with a space: seed reads it without git's trailing tab"

# A diff large enough that a reader quitting at its first match leaves the
# writer to die of SIGPIPE, which pipefail reports as no match.
big="$work/big"
git init --quiet -b main "$big"
git -C "$big" config user.email t@example.com; git -C "$big" config user.name T; git -C "$big" config commit.gpgsign false
printf 'a\n' > "$big/a.txt"
git -C "$big" add -A; git -C "$big" commit --quiet -m base
b0=$(git -C "$big" rev-parse HEAD)
printf 'A\n' > "$big/a.txt"; seq 1 50000 > "$big/z.txt"
git -C "$big" add -A; git -C "$big" commit --quiet -m change
b1=$(git -C "$big" rev-parse HEAD)
o=$(round_cmd start --repo "$big" --base "$b0" --head "$b1" --in-place); bdir=$(val ROUND_DIR "$o")
jq -n '{items:[{id:1, slug:"first", severity:"nit", status:"proposed", finding:"f", reason:"r", sites:[{file:"a.txt", line:1}]}]}' > "$work/big-items.json"
o=$(round_cmd seed --dir "$bdir" --items "$work/big-items.json") || fail "a large diff's first file is changed: $o"
[[ "$(val NOTE_COUNT "$o")" == 1 ]] || fail "a large diff seeds its note: $o"
round_cmd finish --dir "$bdir" >/dev/null
ok "seed: a large diff still finds the file its first rows name"

echo "# all checks passed"
