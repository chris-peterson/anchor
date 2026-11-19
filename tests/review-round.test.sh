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

# A revdiff on PATH answering --dump-keys, so the table's key rows are this
# stub's and not whatever the host has installed.
mkdir -p "$work/bin"
cat > "$work/bin/revdiff" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "version: ${REVDIFF_STUB_VERSION:-v1.14.0}"; exit 0; }
[ "${1:-}" = --dump-keys ] && printf '%s\n' 'map ] next_hunk' 'map [ prev_hunk' 'map a confirm' 'map A annotate_file'
exit 0
EOF
chmod +x "$work/bin/revdiff"
export PATH="$work/bin:$PATH"

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
# A table's boxes as one line of text, so a sentence the box wrapped reads whole.
boxed() { sed -n 's/^│ \(.*\)│$/\1/p' "$1" | tr -s ' \n' ' '; }

# ============================ start ======================================

printf 'stray\n' >> "$repo/b.txt"
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place || true)
[[ "$(val ROUND_ERROR "$o")" == *"uncommitted changes"* ]] || fail "a dirty checkout should be refused: $o"
git -C "$repo" checkout --quiet -- b.txt
ok "start: an in-place round refuses a checkout with uncommitted changes"

printf 'stray\n' > "$repo/stray.txt"
mkdir -p "$repo/scratch"; printf 'x\n' > "$repo/scratch/notes.txt"
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place || true)
[[ "$(val ROUND_ERROR "$o")" == *"untracked files (scratch/, stray.txt)"* ]] || fail "untracked files should be refused by name: $o"
rm -rf "$repo/stray.txt" "$repo/scratch"
printf 'stray.txt\n' >> "$repo/.git/info/exclude"
printf 'stray\n' > "$repo/stray.txt"
o=$(round_cmd start --repo "$repo" --base "$base" --head "$head" --in-place) || fail "an ignored file is not the round's: $o"
round_cmd finish --dir "$(val ROUND_DIR "$o")" >/dev/null
rm -f "$repo/stray.txt"
ok "start: an in-place round refuses untracked files, naming them, and lets ignored ones be"

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
o=$(round_cmd seed --dir "$dir" --pass items --items "$items" --title "Review of #7: Tidy the list" --cr-url "https://example.com/pr/7")
notes=$(val NOTES "$o")
[[ "$(val NOTE_COUNT "$o")" == 3 ]] || fail "one note per item: $o"
# Each note sits above its site, an unchanged line included.
grep -qx '## a.txt:1 ( )' "$notes" || fail "item 1 sits above line 2, on unchanged line 1: $(cat "$notes")"
grep -qx '## a.txt:8 ( )' "$notes" || fail "item 2 sits above its insertion: $(cat "$notes")"
grep -qx '## a.txt:10 ( )' "$notes" || fail "item 3 sits above line 11, near the insertion: $(cat "$notes")"
grep -qx '💡 #3 rename-ten · important · proposed' "$notes" || fail "a proposal's header names its status"
grep -qx '💡 #1 upper-two · nit' "$notes" || fail "an applied item's header carries no status"
grep -qx 'Also: c.txt.' "$notes" || fail "an item's other sites are named in its one note: $(cat "$notes")"
! grep -q '^## c.txt' "$notes" || fail "a later site gets no note of its own: $(cat "$notes")"
table="$root/(context).md"
grep -qx '| 1 | upper-two | nit | in the diff | Line 2 reads \\| better upper |' "$table" || fail "table row 1: $(cat "$table")"
grep -qx '| 3 | rename-ten | important | proposed | Line 10 should be renamed |' "$table" || fail "table row 3"
[[ -z "$(git -C "$root" status --porcelain --untracked-files=all -- '(context).md')" ]] || fail "git leaves the table out of status"
ok "seed: notes sit above their lines with the right marker, and the table lists every item, out of git's sight"

grep -qx '# Review of #7: Tidy the list' "$table" || fail "a first round is the review, not round 1: $(head -1 "$table")"
! grep -qi 'round 1' "$table" || fail "a first round is never numbered: $(cat "$table")"
grep -q 'has 3 items for you: 2 drafted' "$table" || fail "the table says what the review found: $(cat "$table")"
grep -q "This diff holds only those drafts, from the change request's head" "$table" \
  || fail "the items pass says it shows only the drafts: $(cat "$table")"
# shellcheck disable=SC2016
boxed "$table" | grep -qF -- '- `approve`: the agent takes out what you dropped and makes the changes you asked for, then opens the commit for you to approve' \
  || fail "the items pass says Accept leads to the commit: $(cat "$table")"
[[ "$(val ROUND_FROM "$o")" == "$head" ]] || fail "the items pass diffs from the CR head: $o"
sed -n '/^╭─ Review /,/^╰/p' "$table" | grep -qF 'Answer each item on its note in the diff, or on its row' \
  || fail "the Review box says how to answer an item: $(cat "$table")"
# shellcheck disable=SC2016
boxed "$table" | grep -qF -- 'leave a single note here saying `approve` or `reject`' \
  || fail "the Review box says how to finish: $(cat "$table")"
grep -q "on \`$(git -C "$root" branch --show-current)\` · \[change request\](https://example.com/pr/7)" "$table" \
  || fail "the table names the branch and links the CR: $(cat "$table")"
grep -qF "This file, \`(context).md\`, is the guide to the review" "$table" || fail "the table says what it is"
# shellcheck disable=SC2016
[ "$(sed -n '/^```diff$/,/^```$/{/^ [a-z]/p;}' "$table")" = "$(printf '%s\n' ' this round · 1 file' ' original change · 2 files')" ] \
  || fail "a first round draws its drafts over the CR: $(cat "$table")"
grep -q '^+█' "$table" || fail "the round's drafts are coloured: $(cat "$table")"
grep -q '░' "$table" || fail "the CR under them is muted: $(cat "$table")"
ok "seed: the table opens by saying what the review is, what each verdict does, and where the change lives"

bad="$work/bad.json"
jq '.items[0].sites = [{"file": "b.txt"}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --pass items --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"b.txt: not changed in this review"* ]] || fail "a whole-file note on an unchanged file should be refused: $o"
jq '.items[2].sites = [{"file": "b.txt", "line": 1}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --pass items --items "$bad")
grep -qF '### 💡 #3 rename-ten · important · proposed at `b.txt:' "$table" \
  || fail "a proposal on a file the pass doesn't change goes to the table: $(cat "$table")"
jq '.items[0].sites = [{"file": "a.txt", "line": 99}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --pass items --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"a.txt:99: not a line of the file"* ]] || fail "a site past the end should be refused: $o"
# revdiff keeps one note per place, so a second item there would replace the
# first, and the read would take the item the reviewer never saw as dropped.
jq '.items[2].sites = [{"file": "a.txt", "line": 2}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --pass items --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"#3 a.txt:2: shares its note's place with #1"* ]] || fail "two items in one place should be refused: $o"
jq '.items[0].sites = [{"file": "c.txt"}]' "$items" > "$bad"
o=$(round_cmd seed --dir "$dir" --pass items --items "$bad" || true)
[[ "$(val ROUND_ERROR "$o")" == *"#2 c.txt: shares its note's place with #1"* ]] && fail "only an item's first site gets a note, so a later one shares no place: $o"
round_cmd seed --dir "$dir" --pass items --items "$items" >/dev/null
ok "seed: a note revdiff would drop is refused before the review opens"

# ============================ read =======================================

# The reviewer keeps item 1, edits item 2's note, deletes item 3's note, and
# adds a note of their own.
returned="$work/notes.returned.json"
jq '[.[] | {body, target:(if .line then "line" else "file" end), file, startLine:.line, endLine:.line, side}]
    | map(if (.body | startswith("💡 #2")) and .file == "a.txt" then .body += "\nUse a constant instead." else . end)
    | map(select(.body | startswith("💡 #3") | not))
    + [{body:"make this five", target:"line", file:"a.txt", startLine:6, endLine:6, side:"new"}]' \
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
    | map(if (.body | startswith("💡 #1")) then .body = "drop"
          elif (.body | startswith("💡 #2")) then .body = ":thumbsup:"
          else .body += "\n\ud83d\udc4d" end)' "$dir/notes.json" > "$returned.words"
o=$(round_cmd read --dir "$dir" --returned "$returned.words")
[[ "$(val DROP "$o")" == 1 && "$(val KEEP "$o")" == "2,3" && "$(val ADDED "$o")" == 0 ]] \
  || fail "answer words: $o"
ok "read: a note answered with drop drops its item, and one answered with a yes keeps it"

# A note that asks something is a question for the agent, wherever it sits: on
# an item's note it leaves the item as it was, and on its own line or in the
# table it is not a note of the reviewer's own (REVIEW-40).
row2=$(grep -n '^| 2 ' "$table" | cut -d: -f1)
jq --argjson n "$row2" '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]
    | map(if (.body | startswith("💡 #1")) then .body += "\nwhy not a constant?  " else . end)
    + [{body:"hmm... why not 6.1.1? the tag would pick up fixes", target:"line", file:"a.txt", startLine:6, endLine:6, side:"new"},
       {body:"does this hold on Windows?", target:"line", file:"(context).md", startLine:1, endLine:1, side:"new"},
       {body:"is this one needed?", target:"line", file:"(context).md", startLine:$n, endLine:$n, side:"new"},
       {body:"make it six, as https://x.test/a?page=2 does with `a ? b : c`", target:"line", file:"a.txt", startLine:7, endLine:7, side:"new"}]' \
  "$dir/notes.json" > "$returned.asks"
o=$(round_cmd read --dir "$dir" --returned "$returned.asks")
r=$(val ROUND_READ "$o")
[[ "$(val KEEP "$o")" == "1,2,3" && -z "$(val CHANGE "$o")" ]] || fail "a question on an item leaves it as it was: $o"
[[ "$(val QUESTIONS "$o")" == 4 && "$(val ADDED "$o")" == 1 ]] || fail "questions apart from the notes of the reviewer's own: $o"
[[ "$(jq -r '.added[0].body' "$r")" == "make it six, as https://x.test/a?page=2 does with \`a ? b : c\`" &&"$(jq '.tableNotes | length' "$r")" == 0 ]] \
  || fail "a question is neither an added note nor a table note: $(jq -c '{added, tableNotes}' "$r")"
[[ "$(jq -c '[.questions[] | [.item, .body]]' "$r")" == '[[null,"hmm... why not 6.1.1? the tag would pick up fixes"],[null,"does this hold on Windows?"],[1,"why not a constant?  "],[2,"is this one needed?"]]' ]] \
  || fail "each question with the item it was asked on: $(jq -c .questions "$r")"
[[ "$(jq '.questions[0].crLine' "$r")" == 6 && "$(jq -r '.questions[2].file' "$r")" == a.txt ]] \
  || fail "a question keeps where it was asked: $(jq -c .questions "$r")"
ok "read: a note that asks something, anywhere in it, is a question for the agent; a ? in a URL or code isn't"

# The next pass opens with the answers, quoted under the rows, so an answer that
# holds a table adds no row the read would take for an item's.
jq -n '{answers: [{question: "hmm... why not 6.1.1?", file: "a.txt", line: 6,
                   answer: "The tag moves; the SHA does not.\n\n| pin | moves |\n|---|---|\n| tag | yes |\nNothing changed."},
                  {question: "does this hold on Windows?", answer: "Not sure: nothing here runs there, so only the author can say."}]}' > "$work/answers.json"
o=$(round_cmd seed --dir "$dir" --pass items --items "$items" --answers "$work/answers.json")
[[ "$(val ANSWER_COUNT "$o")" == 2 ]] || fail "seed --answers counts the answers: $o"
sed -n '/^## Answers to your questions$/,$p' "$table" > "$work/answers.md"
grep -qxF "### ❓ hmm... why not 6.1.1? (\`a.txt:6\`)" "$work/answers.md" || fail "each answer under its question and where it was asked: $(cat "$table")"
grep -qxF '> | tag | yes |' "$work/answers.md" || fail "the answer is quoted: $(cat "$work/answers.md")"
grep -qxF '### ❓ does this hold on Windows?' "$work/answers.md" || fail "a question from the table has no place: $(cat "$work/answers.md")"
o=$(round_cmd read --dir "$dir" --returned <(jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$dir/notes.json"))
[[ "$(val KEEP "$o")" == "1,2,3" && -z "$(val DROP "$o")" ]] || fail "the answers add no rows: $o"
jq '.answers[0] |= del(.answer)' "$work/answers.json" > "$work/answers.bad.json"
o=$(round_cmd seed --dir "$dir" --pass items --items "$items" --answers "$work/answers.bad.json" || true)
[[ "$(val ROUND_ERROR "$o")" == *"--answers needs"* ]] || fail "an answer with no text is refused: $o"
round_cmd seed --dir "$dir" --pass items --items "$items" >/dev/null
ok "seed --answers: the next pass's table opens with each question and its answer, quoted"

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
o=$(round_cmd files --dir "$dir" 2>"$work/files.err")
[[ "$(val ROUND_FILE "$o")" == a.txt ]] || fail "files: $o"
[[ ! -s "$work/files.err" ]] || fail "a snapshot with the table in info/exclude prints nothing on stderr: $(cat "$work/files.err")"
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
jq -n '{items:[{id:1, slug:"two-lines", severity:"suggestion", status:"applied", finding:"Adds x and y",
  reason:"The list needs them.", sites:[{file:"a.txt", line:4}]},
  {id:2, slug:"spell-out", severity:"suggestion", status:"applied", finding:"Spells out 9 and 10",
  reason:"The rest are words.", sites:[{file:"a.txt", line:11}]},
  {id:6, slug:"ask", severity:"suggestion", status:"proposed", finding:"Why five?",
  reason:"Why spell out five?", sites:[{file:"a.txt", line:7}]}]}' > "$wt_items"
o=$(round_cmd seed --dir "$dir" --pass items --items "$wt_items" --title "Review of #9: Theirs")
[[ "$(val ROUND_FROM "$o")" == "$head" ]] || fail "a round on someone else's CR shows its items from the CR head, not the CR again: $o"
{ grep -qx x "$root/a.txt" && grep -qx 'line nine' "$root/a.txt"; } || fail "the drafts stay in the tree, so the diff is the suggestions: $(git -C "$root" diff "$head")"
n1=$(jq -c '.[] | select(.id == 1)' "$dir/notes.json"); n2=$(jq -c '.[] | select(.id == 2)' "$dir/notes.json")
[[ "$(jq -r '"\(.line) \(.side)"' <<<"$n1")" == "3 new" && "$(jq -r '"\(.line) \(.side)"' <<<"$n2")" == "10 new" ]] \
  || fail "each note sits just above the drafted lines it is about, which the diff shows: $n1 $n2"
jq -r .body <<<"$n2" | head -1 | grep -q '^💡 #2 spell-out · suggestion$' || fail "a suggestion's note is headed 💡: $n2"
jq -r .body <<<"$n2" | grep -q '^The rest are words\.' || fail "the note says why: $n2"
! jq -r .body <<<"$n2" | grep -q 'None of it is in this diff' || fail "the note no longer describes the fix in words: $n2"
jq -r '.[] | select(.id == 6) | .body' "$dir/notes.json" | head -1 | grep -q '^💡 #6 ask · suggestion · proposed$' \
  || fail "a proposal is headed 💡 too: $(cat "$dir/notes.json")"
grep -q 'This diff is only the fixes' "$root/(context).md" || fail "the table says the diff is only the suggestions: $(cat "$root/(context).md")"
grep -q 'delete its note or reply no' "$root/(context).md" || fail "the table says how to drop a suggestion: $(cat "$root/(context).md")"
grep -q '| 2 | spell-out | suggestion | in the diff |' "$root/(context).md" || fail "the table marks a fix as in the diff: $(cat "$root/(context).md")"
# shellcheck disable=SC2016
boxed "$root/(context).md" | grep -qF -- '- `approve`: the agent writes what you kept as suggestions' \
  || fail "a round on someone else's CR says Accept writes suggestions: $(cat "$root/(context).md")"
grep -q 'posts nothing until you approve' "$root/(context).md" \
  || fail "a round on someone else's CR posts nothing unapproved: $(cat "$root/(context).md")"
grep -q '← prev' "$root/(context).md" || fail "the round names the keys: $(cat "$root/(context).md")"
GIT_CONFIG_GLOBAL="$work/hints-off" git config --global anchor.hints false
GIT_CONFIG_GLOBAL="$work/hints-off" round_cmd seed --dir "$dir" --pass items --items "$wt_items" --title "Review of #9: Theirs" >/dev/null
! grep -q '← prev\|hide hints' "$root/(context).md" || fail "anchor.hints=false drops the round's keys: $(cat "$root/(context).md")"
grep -q '^╭─ Review ' "$root/(context).md" || fail "the round keeps the Review box: $(cat "$root/(context).md")"
ok "seed: on someone else's CR the items pass shows only the suggested fixes, each with a 💡 note saying why"

rc=0; round_cmd seed --dir "$dir" --pass whole --items "$wt_items" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 64 ]] || fail "seed has no whole pass: exit $rc"
ok "seed: a round has no whole pass; the change as it will land is the commit review's"

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
ok "suggest: a drafted fix becomes a suggestion numbered at the CR head, per forge"

# A kept note keeps its item, and dropping one takes its draft out of the tree.
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$dir/notes.json" > "$returned"
r=$(val ROUND_READ "$(round_cmd read --dir "$dir" --returned "$returned")")
[[ "$(jq -r '[.items[] | "\(.id):\(.decision)"] | join(",")' "$r")" == "1:keep,2:keep,6:keep" ]] \
  || fail "a 💡 note left as seeded keeps its item: $(jq -c '[.items[] | {id, decision}]' "$r")"
o=$(round_cmd revert --dir "$dir" --id 2)
if ! { [[ "$(val REVERTED "$o")" == 2 && ! -e "$dir/items/2.patch" ]] && grep -qx 'line 9' "$root/a.txt" && grep -qx x "$root/a.txt"; }; then
  fail "dropping an item takes its draft out and leaves the others: $o"
fi
ok "read: a kept 💡 note keeps its item, and dropping one reverts its draft alone"

printf 'more\n' >> "$root/b.txt"; sed -i.bak 's/^line 1$/line one/' "$root/a.txt"; rm -f "$root/a.txt.bak"
round_cmd record --dir "$dir" --id 3 >/dev/null
o=$(round_cmd suggest --dir "$dir" --id 3 --forge github)
[[ "$(val SUGGESTIBLE "$o")" == 0 ]] || fail "a two-file fix is not a suggestion: $o"
ok "suggest: a fix across files stays a thread"

round_cmd finish --dir "$dir" >/dev/null
[[ ! -e "$root" ]] || fail "finish should remove the worktree"
git -C "$repo" worktree list | grep -q anchor-review-tree && fail "the worktree is still registered"
ok "finish: the worktree is removed and unregistered"

# A note stays on the line it concerns, near a change or not, and a whole-file
# note stays on its file: revdiff's ] stops at each (stop-at-annotations). A
# note in a file the pass doesn't change goes to the table with an excerpt, is
# answered on its row, and still posts on its own line (UX-10).
far="$work/far"
git init --quiet -b main "$far"
git -C "$far" config user.email t@example.com; git -C "$far" config user.name T; git -C "$far" config commit.gpgsign false
seq 1 40 | sed 's/^/fn_/' > "$far/app.sh"; printf 'unchanged\n' > "$far/other.sh"; printf 'u1\nu2\nu3\n' > "$far/untouched.sh"
git -C "$far" add -A; git -C "$far" commit --quiet -m base
f0=$(git -C "$far" rev-parse HEAD)
o=$(round_cmd start --repo "$far" --base "$f0" --head "$f0" --in-place); fdir=$(val ROUND_DIR "$o")
sed -i.bak -e 's/^fn_5$/fn_5_renamed/' -e 's/^fn_30$/fn_30_renamed/' "$far/app.sh"; rm -f "$far/app.sh.bak"
printf 'changed\n' > "$far/other.sh"
round_cmd record --dir "$fdir" --id 1 >/dev/null
jq -n '{items:[
  {id:1, slug:"near", severity:"suggestion", status:"proposed", finding:"f", reason:"About line 7.", sites:[{file:"app.sh", line:7}]},
  {id:2, slug:"far", severity:"suggestion", status:"proposed", finding:"g", reason:"About line 18.", sites:[{file:"app.sh", line:18}]},
  {id:3, slug:"whole", severity:"suggestion", status:"proposed", finding:"h", reason:"About other.sh.", sites:[{file:"other.sh"}]},
  {id:4, slug:"elsewhere", severity:"suggestion", status:"proposed", finding:"i", reason:"About untouched.sh.", sites:[{file:"untouched.sh", line:2}]}]}' > "$work/far-items.json"
o=$(round_cmd seed --dir "$fdir" --pass items --items "$work/far-items.json")
fnotes=$(val NOTES "$o"); ftable="$far/(context).md"
grep -qx '## app.sh:6 ( )' "$fnotes" || fail "a note near a change stays put: $(cat "$fnotes")"
grep -qx '## app.sh:17 ( )' "$fnotes" || fail "a note far from every change stays on its line: $(cat "$fnotes")"
grep -qx '## other.sh (file-level)' "$fnotes" || fail "a whole-file note stays on its file: $(cat "$fnotes")"
! grep -q '^💡 #4 ' "$fnotes" || fail "a note in an unchanged file is not in the diff: $(cat "$fnotes")"
grep -qF "### 💡 #4 elsewhere · suggestion · proposed at \`untouched.sh:2\`" "$ftable" || fail "the unchanged file's note is in the table: $(cat "$ftable")"
grep -qx '>    2  u2' "$ftable" || fail "the table quotes the line the note concerns: $(cat "$ftable")"
row4=$(grep -n '^| 4 ' "$ftable" | cut -d: -f1)
jq --argjson n "$row4" '[.[] | {body, target:(if .line == null then "file" else "line" end), file, startLine:.line, endLine:.line, side}]
    + [{body:"drop", target:"line", file:"(context).md", startLine:$n, endLine:$n, side:"new"}]' "$fdir/notes.json" > "$work/far-returned.json"
o=$(round_cmd read --dir "$fdir" --returned "$work/far-returned.json")
[[ "$(val DROP "$o")" == 4 && "$(val KEEP "$o")" == "1,2,3" ]] || fail "an unchanged file's item is answered on its row: $o"
jq '[.[] | {body, target:(if .line == null then "file" else "line" end), file, startLine:.line, endLine:.line, side}]' "$fdir/notes.json" > "$work/far-kept.json"
o=$(round_cmd read --dir "$fdir" --returned "$work/far-kept.json")
[[ "$(val KEEP "$o")" == "1,2,3,4" ]] || fail "an item in the table left alone is kept, not read as a deleted note: $o"
[[ "$(jq '.items[] | select(.id == 4) | .notes[0].crLine' "$(val ROUND_READ "$o")")" == 1 ]] \
  || fail "an unchanged file's item still posts on its own line: $(jq -c '.items[3].notes' "$(val ROUND_READ "$o")")"
round_cmd finish --dir "$fdir" >/dev/null
ok "a note stays on its line or its file, and one in an unchanged file goes to the table and is answered on its row"

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
o=$(round_cmd seed --dir "$sdir" --pass read --items "$work/spaced-items.json")
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
o=$(round_cmd seed --dir "$bdir" --pass read --items "$work/big-items.json") || fail "a large diff's first file is changed: $o"
[[ "$(val NOTE_COUNT "$o")" == 1 ]] || fail "a large diff seeds its note: $o"
round_cmd finish --dir "$bdir" >/dev/null
ok "seed: a large diff still finds the file its first rows name"

# ============================ the items pass =============================

# The items pass shows only the round's drafts, and finish records what it
# decided.
tp="$work/two-pass"
git init --quiet -b main "$tp"
git -C "$tp" config user.email t@example.com; git -C "$tp" config user.name T; git -C "$tp" config commit.gpgsign false
seq 1 30 | sed 's/^/row /' > "$tp/m.txt"
git -C "$tp" add -A; git -C "$tp" commit --quiet -m base
t0=$(git -C "$tp" rev-parse HEAD)
sed -i.bak 's/^row 20$/row twenty/' "$tp/m.txt"; rm -f "$tp/m.txt.bak"
git -C "$tp" commit --quiet -am change
t1=$(git -C "$tp" rev-parse HEAD)
o=$(round_cmd start --repo "$tp" --base "$t0" --head "$t1" --in-place); tdir=$(val ROUND_DIR "$o")
sed -i.bak 's/^row 3$/row three/' "$tp/m.txt"; rm -f "$tp/m.txt.bak"
round_cmd record --dir "$tdir" --id 1 >/dev/null
sed -i.bak 's/^row 10$/row ten/' "$tp/m.txt"; rm -f "$tp/m.txt.bak"
round_cmd record --dir "$tdir" --id 2 >/dev/null
jq -n '{items:[
  {id:1, slug:"three", severity:"suggestion", status:"applied", finding:"f", reason:"Spell out 3.", sites:[{file:"m.txt", line:3}]},
  {id:2, slug:"ten", severity:"suggestion", status:"applied", finding:"g", reason:"Spell out 10.", sites:[{file:"m.txt", line:10}]}]}' > "$work/tp-items.json"
o=$(round_cmd seed --dir "$tdir" --pass items --items "$work/tp-items.json")
[[ "$(val ROUND_FROM "$o")" == "$t1" ]] || fail "the items pass diffs from the CR head: $o"
[[ "$(cut -f3 "$tdir/changed.tsv" | sort -nu | tr '\n' ' ')" == "3 10 " ]] \
  || fail "the items pass holds only the drafts, not the CR's own row 20: $(cat "$tdir/changed.tsv")"
# The reviewer drops item 2 and edits a line of their own in the review.
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}] | map(select(.body | startswith("💡 #2") | not))' \
  "$tdir/notes.json" > "$work/tp-ret1.json"
sed -i.bak 's/^row 1$/row one/' "$tp/m.txt"; rm -f "$tp/m.txt.bak"
o=$(round_cmd read --dir "$tdir" --returned "$work/tp-ret1.json")
[[ "$(val DROP "$o")" == 2 && "$(val USER_EDITS "$o")" == 1 ]] || fail "items pass read: $o"
round_cmd revert --dir "$tdir" --id 2 >/dev/null
grep -qx 'row 10' "$tp/m.txt" || fail "the dropped draft comes back out"
ok "items pass: shows only the drafts, and a dropped draft comes back out"

[[ -f "$tp/(context).md" ]] || fail "the items pass's table is in the tree until finish"
o=$(round_cmd finish --dir "$tdir")
tledger=$(val ROUND_LEDGER "$o")
[[ "$(jq -r '.rejected | map(.slug) | join(",")' "$tledger")" == "ten" ]] \
  || fail "the item dropped in the items pass is rejected: $(jq -c '.rejected' "$tledger")"
[[ "$(jq -r '.rounds[0].notes | "\(.kept) \(.dropped)"' "$tledger")" == "1 1" ]] \
  || fail "finish records what the items pass decided: $(jq -c '.rounds[0].notes' "$tledger")"
ok "items pass: finish records what it decided"

# ============================ the read pass ==============================

rp="$work/read-pass"
git init --quiet -b main "$rp"
git -C "$rp" config user.email t@example.com; git -C "$rp" config user.name T; git -C "$rp" config commit.gpgsign false
seq 1 30 | sed 's/^/row /' > "$rp/m.txt"
git -C "$rp" add -A; git -C "$rp" commit --quiet -m base
r0=$(git -C "$rp" rev-parse HEAD)
sed -i.bak 's/^row 20$/row twenty/' "$rp/m.txt"; rm -f "$rp/m.txt.bak"
git -C "$rp" commit --quiet -am change
r1=$(git -C "$rp" rev-parse HEAD)
o=$(round_cmd start --repo "$rp" --base "$r0" --head "$r1" --in-place); rdir=$(val ROUND_DIR "$o")
jq -n '[{id:"T1", author:"ana", mine:false, file:"m.txt", line:20, body:"why spell it out?\nmore", replies:1}]' > "$work/rp-threads.json"
o=$(round_cmd seed --dir "$rdir" --pass read --threads "$work/rp-threads.json" --title "Review of #9: Rows")
[[ "$(val ROUND_FROM "$o")" == "$r0" && "$(val NOTE_COUNT "$o")" == 0 ]] || fail "the read pass diffs from the merge base, with no notes: $o"
grep -q 'change request as written' "$rp/(context).md" || fail "the read pass says what it is: $(cat "$rp/(context).md")"
# shellcheck disable=SC2016
grep -qF -- '- `m.txt:20` · ana: why spell it out? (1 reply)' "$rp/(context).md" || fail "the read pass lists the open threads: $(cat "$rp/(context).md")"
! grep -q 'this round' "$rp/(context).md" || fail "the read pass draws the CR's size alone: $(cat "$rp/(context).md")"
! grep -q '^| # |' "$rp/(context).md" || fail "the read pass has no item table: $(cat "$rp/(context).md")"
# The reviewer leaves one note of their own.
jq -n '[{body:"twenty should stay a number", target:"line", file:"m.txt", startLine:20, endLine:20, side:"new"}]' > "$work/rp-ret0.json"
o=$(round_cmd read --dir "$rdir" --returned "$work/rp-ret0.json")
[[ "$(val ADDED "$o")" == 1 ]] || fail "a note in the read pass is the reviewer's own: $o"
ok "read pass: the change as written, its open threads, and the reviewer's notes read back as new"

sed -i.bak 's/^row twenty$/row 20/' "$rp/m.txt"; rm -f "$rp/m.txt.bak"
round_cmd record --dir "$rdir" --id 1 >/dev/null
o=$(round_cmd seed --dir "$rdir" --pass read || true)
[[ "$(val ROUND_ERROR "$o")" == *"before any item is recorded"* ]] || fail "a read pass after a draft is refused: $o"
jq -n '{items:[{id:1, slug:"keep-number", severity:"suggestion", status:"applied", from:"you",
  finding:"Keep 20 a number", reason:"Twenty should stay a number.", sites:[{file:"m.txt", line:20, side:"old"}]}]}' > "$work/rp-items.json"
o=$(round_cmd seed --dir "$rdir" --pass items --items "$work/rp-items.json") || fail "items pass after a read pass: $o"
grep -q '^#1 keep-number · suggestion · your note$' "$rdir/notes.md" || fail "an item from a note says so: $(cat "$rdir/notes.md")"
grep -q 'has 1 item for you (1 from your notes)' "$rp/(context).md" || fail "the items pass counts the reviewer's notes: $(cat "$rp/(context).md")"
[[ -f "$rdir/read.read.json" ]] || fail "the read pass's answers are kept aside for finish"
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]' "$rdir/notes.json" > "$work/rp-ret1.json"
o=$(round_cmd read --dir "$rdir" --returned "$work/rp-ret1.json")
[[ "$(val KEEP "$o")" == 1 ]] || fail "items pass after a read pass: $o"
o=$(round_cmd finish --dir "$rdir")
[[ "$(jq -r '.rounds[0].notes | "\(.kept) \(.added)"' "$(val ROUND_LEDGER "$o")")" == "1 1" ]] \
  || fail "finish counts the read pass's notes: $(jq -c '.rounds[0].notes' "$(val ROUND_LEDGER "$o")")"
ok "read pass: a read pass after a draft is refused, its notes become marked items, and finish counts them"

# ======================= old-side notes on the CR ========================

# The items pass's old side is the CR head, so a note there anchors on the CR
# head's line (the CR diff's new side). The read pass's old side is the merge
# base, so a note there stays on the CR diff's old side. The CR inserts three
# lines at the top, so head and base number every later line differently.
os="$work/old-side"
git init --quiet -b main "$os"
git -C "$os" config user.email t@example.com; git -C "$os" config user.name T; git -C "$os" config commit.gpgsign false
seq 1 30 | sed 's/^/row /' > "$os/m.txt"
git -C "$os" add -A; git -C "$os" commit --quiet -m base
s0=$(git -C "$os" rev-parse HEAD)
{ printf 'top 1\ntop 2\ntop 3\n'; seq 1 30 | sed 's/^/row /' | sed 's/^row 20$/row twenty/'; } > "$os/m.txt"
git -C "$os" commit --quiet -am change
s1=$(git -C "$os" rev-parse HEAD)
o=$(round_cmd start --repo "$os" --base "$s0" --head "$s1" --in-place); odir=$(val ROUND_DIR "$o")
sed -i.bak 's/^row 10$/row ten/' "$os/m.txt"; rm -f "$os/m.txt.bak"
round_cmd record --dir "$odir" --id 1 >/dev/null
jq -n '{items:[{id:1, slug:"ten", severity:"suggestion", status:"applied", finding:"f", reason:"Spell out 10.", sites:[{file:"m.txt", line:13}]}]}' > "$work/os-items.json"
round_cmd seed --dir "$odir" --pass items --items "$work/os-items.json" >/dev/null
jq '[.[] | {body, target:"line", file, startLine:.line, endLine:.line, side}]
    + [{body:"keep the digits", target:"line", file:"m.txt", startLine:13, endLine:13, side:"old"}]' \
  "$odir/notes.json" > "$work/os-ret1.json"
r=$(val ROUND_READ "$(round_cmd read --dir "$odir" --returned "$work/os-ret1.json")")
read -r cl cs < <(jq -r '.added[0] | "\(.crLine) \(.crSide)"' "$r")
[[ "$cs" == new && "$(git -C "$os" show "$s1:m.txt" | sed -n "${cl}p")" == "row 10" ]] \
  || fail "an items-pass old-side note anchors on the CR head's line it sits on: $(jq -c '.added' "$r")"
[[ "$(jq -r '.items[0].notes[0].crSide' "$r")" == new ]] || fail "a seeded new-side note anchors on the CR's new side: $(jq -c '.items' "$r")"
ok "items pass: an old-side note anchors on the CR head's line, on the CR diff's new side"

round_cmd finish --dir "$odir" >/dev/null
git -C "$os" checkout --quiet -- m.txt
o=$(round_cmd start --repo "$os" --base "$s0" --head "$s1" --in-place); odir=$(val ROUND_DIR "$o")
round_cmd seed --dir "$odir" --pass read >/dev/null
printf '%s\n' '[{"body":"twenty was fine","target":"line","file":"m.txt","startLine":20,"endLine":20,"side":"old"}]' > "$work/os-ret2.json"
r=$(val ROUND_READ "$(round_cmd read --dir "$odir" --returned "$work/os-ret2.json")")
read -r cl cs < <(jq -r '.added[0] | "\(.crLine) \(.crSide)"' "$r")
[[ "$cs" == old && "$(git -C "$os" show "$s0:m.txt" | sed -n "${cl}p")" == "row 20" ]] \
  || fail "a read-pass old-side note stays on the CR base's line: $(jq -c '.added' "$r")"
round_cmd finish --dir "$odir" >/dev/null
ok "read pass: an old-side note stays on the merge base's line, on the CR diff's old side"

# ============================ the next round =============================

# A round offered after one is committed reviews only that round's commit, from
# the head the round before it reviewed, whatever the Review status says.
nr="$work/next-round"
git init --quiet -b main "$nr"
git -C "$nr" config user.email t@example.com; git -C "$nr" config user.name T; git -C "$nr" config commit.gpgsign false
printf 'one\ntwo\n' > "$nr/x.txt"; printf 'a\n' > "$nr/y.txt"
git -C "$nr" add -A; git -C "$nr" commit --quiet -m base
n0=$(git -C "$nr" rev-parse HEAD)
printf 'one\nTWO\n' > "$nr/x.txt"
git -C "$nr" commit --quiet -am change
n1=$(git -C "$nr" rev-parse HEAD)
o=$(round_cmd start --repo "$nr" --base "$n0" --head "$n1" --in-place)
[[ "$(val ROUND_HEAD "$o")" == "$n1" ]] || fail "start prints the head it pins: $o"
o=$(round_cmd finish --dir "$(val ROUND_DIR "$o")"); nledger=$(val ROUND_LEDGER "$o")
[[ "$(jq -r '.rounds[0].head' "$nledger")" == "$n1" ]] || fail "finish records the round's head: $(jq -c '.rounds[0]' "$nledger")"
o=$(round_cmd start --repo "$nr" --next-round --ledger "$nledger" --head HEAD --in-place || true)
[[ "$(val ROUND_ERROR "$o")" == *"nothing is committed on top of round 1's head"* ]] || fail "a next round with no new commit is refused: $o"
rc=0; round_cmd start --repo "$nr" --next-round --base "$n0" --ledger "$nledger" --head HEAD --in-place >/dev/null 2>&1 || rc=$?
[[ "$rc" == 64 ]] || fail "--next-round takes its base from the ledger, not --base: exit $rc"
printf 'b\n' > "$nr/y.txt"
git -C "$nr" commit --quiet -am "round fix"
n2=$(git -C "$nr" rev-parse HEAD)
o=$(round_cmd start --repo "$nr" --next-round --ledger "$nledger" --head HEAD --in-place)
[[ "$(val ROUND_N "$o")" == 2 && "$(val ROUND_BASE "$o")" == "$n1" && "$(val ROUND_HEAD "$o")" == "$n2" ]] \
  || fail "a next round runs from the last round's head to the new one: $o"
ndir=$(val ROUND_DIR "$o")
echo '{"items":[]}' > "$work/nr-items.json"
round_cmd seed --dir "$ndir" --pass read --items "$work/nr-items.json" >/dev/null
[[ "$(cut -f1 "$ndir/changed.tsv" | sort -u)" == y.txt ]] || fail "a next round shows only the round's commit: $(cat "$ndir/changed.tsv")"
round_cmd finish --dir "$ndir" >/dev/null
[[ "$(jq -r '.rounds[1].head' "$nledger")" == "$n2" ]] || fail "round 2's head lands in the ledger: $(jq -c '.rounds[1]' "$nledger")"
ok "next round: start --next-round reviews only the commit on top of the last round's head"

# ============================ the first request ==========================

# The first review started on a head runs the agents unasked; a second start on
# the same head, even one whose review recorded nothing, asks again.
fr="$work/first-request"
git init --quiet -b main "$fr"
git -C "$fr" config user.email t@example.com; git -C "$fr" config user.name T; git -C "$fr" config commit.gpgsign false
printf 'one\n' > "$fr/x.txt"; git -C "$fr" add -A; git -C "$fr" commit --quiet -m base
f0=$(git -C "$fr" rev-parse HEAD)
printf 'two\n' > "$fr/x.txt"; git -C "$fr" commit --quiet -am change
f1=$(git -C "$fr" rev-parse HEAD)
o=$(round_cmd start --repo "$fr" --base "$f0" --head "$f1" --in-place)
[[ "$(val ROUND_FIRST_REQUEST "$o")" == 1 ]] || fail "a head never reviewed here is a first request: $o"
o=$(round_cmd finish --dir "$(val ROUND_DIR "$o")"); fledger=$(val ROUND_LEDGER "$o")
o=$(round_cmd start --repo "$fr" --base "$f0" --head "$f1" --in-place)
[[ "$(val ROUND_FIRST_REQUEST "$o")" == 0 ]] || fail "a head reviewed before is not a first request: $o"
round_cmd finish --dir "$(val ROUND_DIR "$o")" >/dev/null
o=$(round_cmd start --repo "$fr" --base "$f0" --head "$f1" --worktree)
[[ "$(val ROUND_FIRST_REQUEST "$o")" == 0 ]] || fail "a worktree round reads the same record: $o"
round_cmd finish --dir "$(val ROUND_DIR "$o")" >/dev/null
printf 'three\n' > "$fr/x.txt"; git -C "$fr" commit --quiet -am more
o=$(round_cmd start --repo "$fr" --next-round --ledger "$fledger" --head HEAD --in-place)
[[ -z "$(val ROUND_FIRST_REQUEST "$o")" ]] || fail "a next round is the Round question's, not a first request: $o"
round_cmd finish --dir "$(val ROUND_DIR "$o")" >/dev/null
o=$(round_cmd start --repo "$fr" --base "$f0" --head HEAD --in-place)
[[ "$(val ROUND_FIRST_REQUEST "$o")" == 1 ]] || fail "a new head is a first request: $o"
round_cmd finish --dir "$(val ROUND_DIR "$o")" >/dev/null
git -C "$fr" tag later; git -C "$fr" commit --quiet --allow-empty -m newer
o=$(round_cmd start --repo "$fr" --base "$f0" --head later --in-place || true)
[[ "$(val ROUND_ERROR "$o")" == *"not the CR head"* ]] || fail "a start off the head should be refused: $o"
[[ "$(grep -c . "$fr/.git/anchor/review-requests")" == 2 ]] || fail "a refused start records nothing: $(cat "$fr/.git/anchor/review-requests")"
ok "first request: the first review of a head is flagged, every later one isn't, and a next round says nothing"

echo "# all checks passed"
