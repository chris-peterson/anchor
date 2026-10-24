#!/usr/bin/env bash
# Functional test for scripts/review-explain.sh: the notes the agent leaves on
# its own changes before a --local review, anchored where revdiff draws them and
# refused where the review would have nowhere to show them. Requires jq.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
explain="$here/../scripts/review-explain.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-explain-test.XXXXXX")"
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

run() { ( cd "$repo" && bash "$explain" "$@" ); }
notes() { printf '%s\n' "$1" > "$work/in.json"; }

notes '{"notes": [
  {"file": "a.txt", "line": 3, "note": "Spelled out to match the heading."},
  {"file": "c.txt", "note": "  A new file for the fixture.  "}]}'
o=$(run --notes "$work/in.json" --path a.txt --path c.txt)
md=$(val EXPLAIN_NOTES "$o")
[[ "$(val NOTE_COUNT "$o")" == 2 ]] || fail "one note per entry: $o"
grep -qx '## a.txt:2 ( )' "$md" || fail "a note about line 3 sits under line 2, unchanged: $(cat "$md")"
grep -qx 'Spelled out to match the heading.' "$md" || fail "the note's text is the note: $(cat "$md")"
grep -qx '## c.txt:1 (+)' "$md" || fail "a whole-file note moves onto the file's first change: $(cat "$md")"
grep -qx 'A new file for the fixture.' "$md" || fail "the note is trimmed: $(cat "$md")"
[[ -s "${md%.md}.json" ]] || fail "the anchored JSON sits beside the markdown"
[[ -z "$(git -C "$repo" diff --cached --name-only)" ]] || fail "anchoring stages nothing"
ok "notes anchor on their lines, a whole-file note moves onto its change, and nothing is staged"

notes '{"notes": [
  {"file": "a.txt", "line": 25, "note": "far"},
  {"file": "b.txt", "line": 1, "note": "unchanged file"},
  {"file": "c.txt", "line": 1, "note": "outside the paths"},
  {"file": "a.txt", "line": 3, "note": "  "}]}'
rc=0; o=$(run --notes "$work/in.json" --path a.txt --path b.txt) || rc=$?
[[ "$rc" == 65 ]] || fail "unplaceable notes exit 65, got $rc: $o"
grep -q '^EXPLAIN_ERROR=a.txt:25: not near a change' <<<"$o" || fail "a note far from every change is refused: $o"
grep -q '^EXPLAIN_ERROR=b.txt:1: not changed in this review' <<<"$o" || fail "a note on an unchanged file is refused: $o"
grep -q '^EXPLAIN_ERROR=c.txt:1: not in this review' <<<"$o" || fail "a note outside the paths is refused: $o"
grep -q '^EXPLAIN_ERROR=note 4 needs a file and a note' <<<"$o" || fail "an empty note is refused: $o"
[[ -z "$(val EXPLAIN_NOTES "$o")" ]] || fail "nothing is written when a note is refused: $o"
ok "a note the review has nowhere to show is refused, each with its own error"

echo "# all checks passed"
