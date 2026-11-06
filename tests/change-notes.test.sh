#!/usr/bin/env bash
# Functional test for scripts/lib/change-notes.sh: the notes the agent leaves on
# its own changes in a --local review, anchored where revdiff draws them and
# refused where the review would have nowhere to show them. Requires jq.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../scripts/lib"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-change-notes-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false
seq 1 30 | sed 's/^/line /' > "$repo/a.txt"
printf 'keep\n' > "$repo/b.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m base
sed -i.bak 's/^line 3$/line three/' "$repo/a.txt"; rm -f "$repo/a.txt.bak"
printf 'new\n' > "$repo/c.txt"

run() {
  ( cd "$repo"
    # shellcheck source=../scripts/lib/tmpfile.sh
    source "$lib/tmpfile.sh"
    # shellcheck source=../scripts/lib/stage-paths.sh
    source "$lib/stage-paths.sh"
    # shellcheck source=../scripts/lib/item-review.sh
    source "$lib/item-review.sh"
    # shellcheck source=../scripts/lib/change-notes.sh
    source "$lib/change-notes.sh"
    anchor_change_notes_place "$@" )
}
notes() { printf '%s\n' "$1" > "$work/in.json"; }

notes '{"notes": [
  {"file": "a.txt", "line": 3, "note": "Spelled out to match the heading."},
  {"file": "c.txt", "note": "  A new file for the fixture.  "}]}'
md=$(run "$work/in.json" a.txt c.txt)
[[ "$(jq length "${md%.md}.json")" == 2 ]] || fail "one note per entry: $(cat "${md%.md}.json")"
grep -qx '## a.txt:2 ( )' "$md" || fail "a note about line 3 sits under line 2, unchanged: $(cat "$md")"
grep -qx 'Spelled out to match the heading.' "$md" || fail "the note's text is the note: $(cat "$md")"
grep -qx '## c.txt (file-level)' "$md" || fail "a whole-file note sits on its file: $(cat "$md")"
grep -qx 'A new file for the fixture.' "$md" || fail "the note is trimmed: $(cat "$md")"
[[ -s "${md%.md}.json" ]] || fail "the anchored JSON sits beside the markdown"
[[ -z "$(git -C "$repo" diff --cached --name-only)" ]] || fail "anchoring stages nothing"
ok "notes anchor on their lines, a whole-file note on its file, and nothing is staged"

notes '{"notes": [
  {"file": "a.txt", "line": 25, "note": "far"},
  {"file": "b.txt", "line": 1, "note": "unchanged file"},
  {"file": "c.txt", "line": 1, "note": "outside the paths"},
  {"file": "a.txt", "line": 3, "note": "  "}]}'
rc=0; o=$(run "$work/in.json" a.txt b.txt) || rc=$?
[[ "$rc" == 65 ]] || fail "unplaceable notes exit 65, got $rc: $o"
grep -q '^NOTES_ERROR=a.txt:25: not near a change' <<<"$o" || fail "a note far from every change is refused: $o"
grep -q '^NOTES_ERROR=b.txt:1: not changed in this review' <<<"$o" || fail "a note on an unchanged file is refused: $o"
grep -q '^NOTES_ERROR=c.txt:1: not in this review' <<<"$o" || fail "a note outside the paths is refused: $o"
grep -q '^NOTES_ERROR=note 4 needs a file and a note' <<<"$o" || fail "an empty note is refused: $o"
grep -v "^NOTES_ERROR=" <<<"$o" | grep -q . && fail "nothing is written when a note is refused: $o"
ok "a note the review has nowhere to show is refused, each with its own error"

echo "# all checks passed"
