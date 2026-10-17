#!/usr/bin/env bash
# Functional test for scripts/batch-edit.sh: the scratch tree a batch of drafted
# edits is reviewed in, the notes and table it seeds, and how it reads the
# reviewer's answer back for each item. Requires jq.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
batch="$here/../scripts/batch-edit.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-batch-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Batches land in here, so a run that leaves one behind is caught below.
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
leftovers() { find "$TMPDIR" -maxdepth 1 -name 'anchor-batch.*' | wc -l | tr -d ' '; }

b() { bash "$batch" "$@"; }

printf 'title: Retry uploads\nlabels: bug\nstate: open\n---\n\nUploads fail on 503.\n' > "$work/7.current"
printf 'title: Retry uploads on 503\nlabels: bug, uploader\nstate: open\n---\n\nUploads fail on 503.\n\nRetry them with backoff.\n' > "$work/7.proposed"
printf 'title: Old docs\nlabels: docs\nstate: open\n---\n\nThe page is stale.\n' > "$work/8.current"
printf 'title: Old docs\nlabels: docs\nstate: closed\n---\n\nThe page is stale.\n' > "$work/8.proposed"
printf 'addressed in abc1234\n' > "$work/r1.proposed"

items="$work/items.json"
cat > "$items" <<EOF
{"items": [
  {"id": 7, "file": "issues/7.md", "current": "$work/7.current", "proposed": "$work/7.proposed",
   "summary": "Retitle | relabel, add the fix", "url": "https://example.com/issues/7",
   "notes": [{"line": 8, "body": "From the thread on #6."}, {"body": "Labels follow the repo's set."}]},
  {"id": 8, "file": "issues/8.md", "current": "$work/8.current", "proposed": "$work/8.proposed",
   "summary": "Close as done"},
  {"id": "r1", "file": "replies/1.md", "proposed": "$work/r1.proposed",
   "summary": "Reply on deploy.sh:42", "notes": [{"line": 1, "body": "The fix landed as abc1234."}]}
]}
EOF

# ============================ start ======================================

bad="$work/bad.json"
jq --arg c "$work/7.current" '.items[1].proposed = $c | .items[1].current = $c' "$items" > "$bad"
o=$(b start --items "$bad" || true)
[[ "$(val BATCH_ERROR "$o")" == *"is the current text"* ]] || fail "an item that changes nothing should be refused: $o"
jq '.items[1].file = "../x.md"' "$items" > "$bad"
o=$(b start --items "$bad" || true)
[[ "$(val BATCH_ERROR "$o")" == *"relative path inside the batch"* ]] || fail "a path outside the batch should be refused: $o"
jq '.items[1].id = 7' "$items" > "$bad"
o=$(b start --items "$bad" || true)
[[ "$(val BATCH_ERROR "$o")" == *"ids used more than once: 7"* ]] || fail "a repeated id should be refused: $o"
jq '.items[0].notes[0].line = 40' "$items" > "$bad"
o=$(b start --items "$bad" || true)
[[ "$(val BATCH_ERROR "$o")" == *"issues/7.md:40: not a line"* ]] || fail "a note past the end should be refused: $o"
ok "start: an empty edit, a path outside the batch, a repeated id, and a note off the text are refused"

# A header that never closes would publish its fields as body text.
printf 'title: Retry uploads on 503\nlabels: bug\nstate: open\n---## Context\nUploads fail.' > "$work/7.broken"
jq --arg p "$work/7.broken" '.items[0].proposed = $p | .items[0].notes = []' "$items" > "$bad"
o=$(b start --items "$bad" || true)
[[ "$(val BATCH_ERROR "$o")" == *"item 7 issues/7.md: opens with key: value lines but no --- line ends the header"* ]] \
  || fail "a header with no closing --- line should be refused: $o"
printf 'Note: the retry is in abc1234.\n' > "$work/r1.note"
jq --arg p "$work/r1.note" '.items[2].proposed = $p' "$items" > "$bad"
o=$(b start --items "$bad")
[[ -z "$(val BATCH_ERROR "$o")" ]] || fail "a one-line reply that happens to start key: value is a body: $o"
b finish --dir "$(val BATCH_DIR "$o")" >/dev/null
ok "start: a text that opens like a header but never closes one is refused, and a one-line reply is not"

jq '.items[1].id = "#" | .items[2].id = ""' "$items" > "$bad"
o=$(b start --items "$bad" || true)
[[ "$(grep -c 'an id is one line of text other than #' <<<"$o")" == 2 ]] || fail "an empty id and # should be refused: $o"
[[ "$(leftovers)" == 0 ]] || fail "a refused start should leave no batch behind: $(ls "$TMPDIR")"
ok "start: an empty id and a bare # are refused, and no refused start leaves a batch behind"

o=$(b start --items "$items" --title "Batch edit of 3 items")
dir=$(val BATCH_DIR "$o"); root=$(val BATCH_ROOT "$o"); base=$(val BATCH_BASE "$o")
[[ "$(val ITEM_COUNT "$o")" == 3 && "$(val NOTE_COUNT "$o")" == 5 ]] || fail "counts: $o"
[[ "$(git -C "$root" show "$base:issues/7.md")" == "$(cat "$work/7.current")" ]] || fail "the base holds the current text"
cmp -s "$root/issues/7.md" "$work/7.proposed" || fail "the tree holds the proposed text"
[[ "$(git -C "$root" status --porcelain -- replies/1.md)" == "?? replies/1.md" ]] || fail "a new item is an untracked file"
ok "start: the current text is the base and the proposed text is the tree, with a new item as a new file"

notes=$(val NOTES "$o")
# line 8 of issues/7.md ("Retry them with backoff.") is added, line 7 (blank) too
grep -qx '## issues/7.md:7 (+)' "$notes" || fail "a note sits above its line, on the added side: $(cat "$notes")"
grep -qx '## issues/7.md (file-level)' "$notes" || fail "a note with no line is a file note"
grep -qxF '🗒 #7 · Retry uploads on 503' "$notes" || fail "an item opens with a note naming it by its title: $(cat "$notes")"
grep -qxF '🔗 https://example.com/issues/7' "$notes" || fail "the opening note links the item"
grep -qxF "Labels follow the repo's set." "$notes" || fail "a file note folds in under the opening note"
[[ "$(grep -c '^## issues/7.md (file-level)$' "$notes")" == 1 ]] || fail "one file-level note per file"
grep -qxF '✨ #r1 · Reply on deploy.sh:42' "$notes" || fail "a new item with no header is named by its summary: $(cat "$notes")"
grep -qx '## replies/1.md:1 (+)' "$notes" || fail "a note on line 1 of a new file sits on line 1, added: $(cat "$notes")"
table=$(val TABLE "$o")
[[ "$table" == "$root/.batch-edit.md" ]] || fail "table path: $table"
grep -qx '# Batch edit of 3 items' "$table" || fail "table title"
grep -qxF '| 7 | issues/7.md | Retitle \| relabel, add the fix | [link](https://example.com/issues/7) |' "$table" || fail "row 7: $(cat "$table")"
grep -qxF '| r1 | replies/1.md | new: Reply on deploy.sh:42 |  |' "$table" || fail "row r1: $(cat "$table")"
ok "start: notes anchor above their lines with the right marker, and the table has a row per item with its link"

# ============================ read =======================================

# Leaving everything as seeded keeps every item.
jq '[.[] | {body, target:(if .line then "line" else "file" end), file, startLine:.line, endLine:.line, side}]' \
  "$dir/notes.json" > "$work/returned.json"
o=$(b read --dir "$dir" --returned "$work/returned.json")
[[ "$(val KEEP "$o")" == "7,8,r1" && -z "$(val CHANGE "$o")$(val EDITED "$o")$(val DROP "$o")" ]] || fail "all kept: $o"
r=$(val BATCH_READ "$o")
[[ "$(jq -r '.items[0].fields.title' "$r")" == "Retry uploads on 503" ]] || fail "fields: $(jq -c '.items[0].fields' "$r")"
[[ "$(jq -r '.items[0].fields.labels' "$r")" == "bug, uploader" ]] || fail "labels field"
[[ "$(head -1 "$(jq -r '.items[0].body' "$r")")" == "Uploads fail on 503." ]] || fail "body starts after the header and its blank line"
[[ "$(jq -r '.items[0].url' "$r")" == "https://example.com/issues/7" ]] || fail "an item carries its url"
[[ "$(jq -r '.items[2].fields' "$r")" == null ]] || fail "an item seeded without a header has no fields"
[[ "$(cat "$(jq -r '.items[2].body' "$r")")" == "addressed in abc1234" ]] || fail "a headerless body is the whole text"
ok "read: an untouched review keeps every item, with header fields split from the body"

# The reviewer edits item 8's file, notes on item 7, and deletes r1's row.
awk '{ print } $0 == "state: closed" { print "reason: completed" }' "$work/8.proposed" > "$root/issues/8.md"
grep -v '^| r1 ' "$table" > "$table.tmp"; mv "$table.tmp" "$table"
jq '. + [{body:"say which release", target:"line", file:"issues/7.md", startLine:9, endLine:9, side:"new"}]' \
  "$work/returned.json" > "$work/returned.2.json"
o=$(b read --dir "$dir" --returned "$work/returned.2.json")
[[ "$(val CHANGE "$o")" == 7 && "$(val EDITED "$o")" == 8 && "$(val DROP "$o")" == r1 && -z "$(val KEEP "$o")" ]] \
  || fail "decisions: $o"
r=$(val BATCH_READ "$o")
[[ "$(jq -r '.items[0].notes[0]' "$r")" == "say which release" ]] || fail "a new note is the feedback"
[[ "$(jq -r '.items[1].fields.reason' "$r")" == "completed" ]] || fail "an edited file's fields come back as edited"
ok "read: a new note changes an item, an edited file is the reviewer's text, and a deleted row drops"

# An edited seeded note, a note on a row, and a note off the rows.
row8=$(grep -n '^| 8 ' "$table" | cut -d: -f1)
jq --argjson n "$row8" 'map(if .file == "issues/7.md" and .target == "file" then .body = "Labels: drop uploader." else . end)
    | map(select(.body != "say which release"))
    + [{body:"close it as not planned", target:"line", file:".batch-edit.md", startLine:$n, endLine:$n, side:"new"},
       {body:"hold all of these until Monday", target:"line", file:".batch-edit.md", startLine:1, endLine:1, side:"new"}]' \
  "$work/returned.2.json" > "$work/returned.3.json"
o=$(b read --dir "$dir" --returned "$work/returned.3.json")
[[ "$(val CHANGE "$o")" == "7,8" && "$(val GENERAL "$o")" == 1 ]] || fail "row note and edited note: $o"
r=$(val BATCH_READ "$o")
[[ "$(jq -r '.items[0].notes[0]' "$r")" == "Labels: drop uploader." ]] || fail "an edited seeded note is feedback"
[[ "$(jq -r '.items[1].rowNotes[0]' "$r")" == "close it as not planned" ]] || fail "row note text"
[[ "$(jq -r '.general[0]' "$r")" == "hold all of these until Monday" ]] || fail "general note"
ok "read: an edited note or a note on a row changes an item, and a note off the rows is general"

# A deleted seeded note is tidying, not feedback.
cp "$work/8.proposed" "$root/issues/8.md"
jq 'map(select(.file != "issues/7.md"))' "$work/returned.json" > "$work/returned.4.json"
o=$(b read --dir "$dir" --returned "$work/returned.4.json")
[[ "$(val KEEP "$o")" == "7,8" ]] || fail "a deleted note keeps the item: $o"
ok "read: deleting a seeded note leaves the item kept"

# A header the reviewer broke can't be split, so the item comes back to be redrafted.
sed -i.bak 's/^---$/===/' "$root/issues/7.md"; rm -f "$root/issues/7.md.bak"
o=$(b read --dir "$dir" --returned "$work/returned.json")
[[ "$(val CHANGE "$o")" == 7 ]] || fail "a broken header should change the item: $o"
[[ "$(jq -r '.items[0].fieldsError' "$(val BATCH_READ "$o")")" == *"no longer parses"* ]] || fail "fieldsError"
ok "read: a header that no longer parses sends the item back"

# An id that starts with # or holds a | survives the table, and its row reads back.
b finish --dir "$dir" >/dev/null
jq '.items[0].id = "#4" | .items[1].id = "a|b"' "$items" > "$bad"
o=$(b start --items "$bad")
dir=$(val BATCH_DIR "$o"); table=$(val TABLE "$o")
[[ -n "$dir" ]] || fail "an id starting with # should start: $o"
grep -qF '| #4 | issues/7.md |' "$table" || fail "row #4: $(cat "$table")"
grep -qF '| a\|b | issues/8.md |' "$table" || fail "an id's | is escaped: $(cat "$table")"
grep -qxF '🗒 #4 · Retry uploads on 503' "$(val NOTES "$o")" || fail "an id already starting with # is not prefixed again"
jq '[.[] | {body, target:(if .line then "line" else "file" end), file, startLine:.line, endLine:.line, side}]' \
  "$dir/notes.json" > "$work/returned.5.json"
o=$(b read --dir "$dir" --returned "$work/returned.5.json")
[[ "$(val KEEP "$o")" == "#4,a|b,r1" ]] || fail "rows with these ids should read back as kept: $o"
grep -vF '| #4 |' "$table" > "$table.tmp"; mv "$table.tmp" "$table"
o=$(b read --dir "$dir" --returned "$work/returned.5.json")
[[ "$(val DROP "$o")" == "#4" ]] || fail "deleting row #4 drops it: $o"
ok "start: an id starting with # or holding a | gets an escaped row that reads back"

# ============================ finish =====================================

o=$(b finish --dir "$dir")
[[ "$(val FINISHED "$o")" == 1 && ! -e "$dir" ]] || fail "finish should remove the batch: $o"
[[ "$(leftovers)" == 0 ]] || fail "every batch this suite started should be gone: $(ls "$TMPDIR")"
ok "finish: the batch and its tree are gone"
