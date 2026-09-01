#!/usr/bin/env bash
# Functional test for scripts/deep-links.sh — the deep links a CR description's
# Review guide points at. Covers token resolution (the author names what they are
# pointing at; the script finds the line), placeholder expansion, and the
# --verify backstop for links written without a placeholder.
#
# Asserts the forge-specific hash and view path, and that the hashes match what
# the forges actually render: GitLab anchors a file by sha1(path), GitHub by
# sha256(path).
# ci-platforms: linux macos windows
#   The anchors are path hashes and the hashing binary varies — macOS ships
#   shasum with no sha1sum.

set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
links="$here/../scripts/deep-links.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-deep-links-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false
printf 'seed\n' > "$repo/seed.txt"
# app.txt's seed lines survive the change below, so `settled` is a token that is
# in the file but on no changed line — the "present but unchanged" case.
printf 'a1\nsettled\na3\na4\na5\n' > "$repo/app.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m seed
git -C "$repo" checkout --quiet -b feat
mkdir -p "$repo/src"
printf 'one\n' > "$repo/src/cli.ts"
printf 'two\n' > "$repo/docs.md"
# Line 3 changed and line 4 blanked, so app.txt carries a changed non-blank line,
# a changed blank line, and untouched lines — one file covering every verdict.
# Lines 6-8 add a token on three changed lines (ambiguous), one on a single
# changed line (unique), and a section heading with spaces and parentheses. The
# last line carries a backslash, which is what an escape-processing assignment
# eats on the way into awk.
printf 'a1\nsettled\nchanged\n\na5\nFILE_LINKS one\nFILE_LINKS two\n## Deep-link construction (Review guide)\nsolitary\nesc [][\\.*^$]\n' \
  > "$repo/app.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m change

run() { ( cd "$repo" && bash "$links" "$@" ); }

# Reference hashes, computed here rather than by calling the script. Which
# binary exists is itself the platform difference this test runs the matrix for:
# macOS has `shasum` and no `sha1sum`, Windows Git Bash has `sha1sum`/`sha256sum`
# and no `shasum`, and distros vary — so the test can't hardcode either name.
ref_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$2" | shasum -a "$1" | cut -d' ' -f1
  elif command -v "sha${1}sum" >/dev/null 2>&1; then
    printf '%s' "$2" | "sha${1}sum" | cut -d' ' -f1
  else
    fail "no sha$1 tool available to compute a reference hash"
  fi
}

gh_url=https://github.com/o/r/pull/32
gl_url=https://gitlab.com/g/p/-/merge_requests/7
gh_app="$gh_url/changes#diff-$(ref_hash 256 app.txt)"
gl_app="$gl_url/diffs#$(ref_hash 1 app.txt)"
gh_cli="$gh_url/changes#diff-$(ref_hash 256 src/cli.ts)"

gh() { run --forge github --cr-url "$gh_url" --base main "$@"; }
gl() { run --forge gitlab --cr-url "$gl_url" --base main "$@"; }

# --- --resolve: a unique token, on both forges --------------------------------
o=$(gh --resolve app.txt 'solitary')
[ "$(val LINE "$o")" = 9 ]                || fail "expected line 9; got: $o"
[ "$(val LINK "$o")" = "${gh_app}R9" ]    || fail "github link wrong: $o"
ok "github: a unique token resolves to /changes + sha256(path) + R<line>"

o=$(gl --resolve app.txt 'solitary')
[ "$(val LINK "$o")" = "${gl_app}_9_9" ]  || fail "gitlab link wrong: $o"
ok "gitlab: the same token resolves to /diffs + sha1(path) + _<line>_<line>"

# A section heading is a normal thing to point at — the identifier the bullet
# names often sits in the body below it, not on the heading line.
o=$(gh --resolve app.txt '## Deep-link construction (Review guide)')
[ "$(val LINE "$o")" = 8 ] || fail "a heading with spaces and parens should resolve; got: $o"
ok "a section heading works as a token"

# An empty token is a file-level link: the prefix, no line part.
o=$(gh --resolve src/cli.ts '')
[ "$(val LINK "$o")" = "$gh_cli" ] || fail "file-level link wrong: $o"
[ -z "$(val LINE "$o")" ]          || fail "a file-level link has no line: $o"
ok "an empty token gives the bare file-level link"

# --- --resolve: the four ways a token fails to name one line ------------------
o=$(gh --resolve app.txt 'FILE_LINKS') && fail "an ambiguous token must exit non-zero: $o"
grep -q '^UNRESOLVED ambiguous app.txt FILE_LINKS' <<<"$o" || fail "not reported ambiguous: $o"
grep -q '6: FILE_LINKS one' <<<"$o" || fail "candidates must carry the line content: $o"
grep -q '7: FILE_LINKS two' <<<"$o" || fail "every candidate must be listed: $o"
ok "several in-hunk matches list the candidates rather than taking the first"

o=$(gh --resolve app.txt 'settled') && fail "an unchanged-line token must exit non-zero: $o"
grep -q '^UNRESOLVED unchanged app.txt settled' <<<"$o" || fail "not reported unchanged: $o"
grep -q '2: settled' <<<"$o" || fail "should say where it does appear: $o"
ok "a token present in the file but on no changed line reports unchanged"

o=$(gh --resolve app.txt 'nowhere-at-all') && fail "an absent token must exit non-zero: $o"
grep -q '^UNRESOLVED absent app.txt nowhere-at-all' <<<"$o" || fail "not reported absent: $o"
ok "a token in no line of the file reports absent, distinct from unchanged"

o=$(gh --resolve seed.txt 'seed') && fail "a path outside the range must exit non-zero: $o"
grep -q '^UNRESOLVED unknown-file seed.txt' <<<"$o" || fail "not reported unknown-file: $o"
ok "a path the range doesn't touch reports unknown-file"

# --- --check: resolution without a CR, which is what defers the open ----------
draft="$work/draft.md"
cat > "$draft" <<EOF
## Review guide

- [\`app.txt\`](anchor:app.txt#solitary) — the new bit
- [\`app.txt\`](<anchor:app.txt### Deep-link construction (Review guide)>) — a heading
- [\`src/cli.ts\`](anchor:src/cli.ts) — file-level
EOF
o=$(run --check "$draft" --base main) || fail "a clean draft should pass --check: $o"
[ "$(val PLACEHOLDERS "$o")" = 3 ] || fail "expected 3 placeholders; got: $o"
[ "$(val UNRESOLVED "$o")" = 0 ]   || fail "expected 0 unresolved; got: $o"
ok "--check resolves every placeholder with no forge and no CR URL"

cat > "$draft" <<EOF
- [\`app.txt\`](anchor:app.txt#FILE_LINKS)
- see anchor:app.txt#solitary in prose
EOF
o=$(run --check "$draft" --base main) && fail "a broken draft should exit non-zero: $o"
[ "$(val UNRESOLVED "$o")" = 2 ] || fail "expected 2 unresolved; got: $o"
grep -q '^UNRESOLVED ambiguous' <<<"$o" || fail "missed the ambiguous placeholder: $o"
grep -q '^UNRESOLVED malformed' <<<"$o" \
  || fail "an anchor: written as prose must not pass silently: $o"
ok "--check reports an ambiguous placeholder and an anchor: outside a link"

# A description that names the skill which drafted it carries the same prefix a
# placeholder does. Reading `/anchor:prepare-review` as broken markup reports a
# fault in prose the author wrote on purpose.
cat > "$draft" <<EOF
Run \`/anchor:prepare-review\` again, then \`/anchor:commit\`.

- [\`app.txt\`](anchor:app.txt#solitary) — the new bit
EOF
o=$(run --check "$draft" --base main) || fail "a skill mention should not fail --check: $o"
[ "$(val PLACEHOLDERS "$o")" = 1 ] || fail "expected 1 placeholder; got: $o"
[ "$(val UNRESOLVED "$o")" = 0 ]   || fail "expected 0 unresolved; got: $o"
ok "--check reads /anchor:<skill> as prose, not as a broken placeholder"

# A token carrying a backslash — a regex, an escaped character — is what an
# escape-processing awk assignment strips on the way in. The token then matches
# nothing and reports as `unchanged`, which sends the author looking for a line
# that is right in front of them.
cat > "$draft" <<'EOF'
- [`app.txt`](anchor:app.txt#[][\.*^$]) — the character class
EOF
o=$(run --check "$draft" --base main) || fail "a backslash token should resolve: $o"
[ "$(val UNRESOLVED "$o")" = 0 ] || fail "a token with a backslash must resolve; got: $o"
ok "--check matches a token carrying a backslash"

# --- --expand: the finished URLs, written back in place -----------------------
cat > "$draft" <<EOF
- [\`app.txt\`](anchor:app.txt#solitary) — one
- [\`app.txt\`](<anchor:app.txt### Deep-link construction (Review guide)>) — two
- [\`src/cli.ts\`](anchor:src/cli.ts) — three
EOF
o=$(gh --expand "$draft") || fail "expansion of a clean draft should succeed: $o"
[ "$(val EXPANDED "$o")" = 3 ] || fail "expected 3 expansions; got: $o"
grep -qF "(${gh_app}R9)" "$draft"  || fail "the unique token's link is wrong: $(cat "$draft")"
grep -qF "(${gh_app}R8)" "$draft"  || fail "the heading's link is wrong: $(cat "$draft")"
grep -qF "(${gh_cli})"   "$draft"  || fail "the file-level link is wrong: $(cat "$draft")"
grep -q 'anchor:' "$draft" && fail "no placeholder should survive: $(cat "$draft")"
grep -q -- '— one' "$draft" || fail "the bullet prose must survive: $(cat "$draft")"
ok "--expand rewrites every placeholder in place and leaves the prose alone"

# All-or-nothing: one unresolved placeholder must not half-rewrite a description
# that is already approved and, by this point, already on the forge.
cat > "$draft" <<EOF
- [\`a\`](anchor:app.txt#solitary) — resolves
- [\`b\`](anchor:app.txt#FILE_LINKS) — ambiguous
EOF
cp "$draft" "$work/before.md"
o=$(gh --expand "$draft") && fail "expansion with an unresolved placeholder must fail: $o"
cmp -s "$work/before.md" "$draft" \
  || fail "the draft must be untouched on failure: $(cat "$draft")"
ok "--expand leaves the file untouched when any placeholder is unresolved"

cat > "$draft" <<EOF
- [\`a\`](anchor:app.txt#solitary)
EOF
o=$(run --expand "$draft" --forge github --cr-url '' --base main 2>/dev/null) \
  && fail "--expand with no CR URL must not silently drop the links: $o"
ok "--expand refuses to finish placeholders without a CR URL"

# --- --verify: the backstop for links written without a placeholder -----------
verify() { ( cd "$repo" && bash "$links" --verify "$draft" --forge "$1" --cr-url "$2" --base main ); }

printf '%s\n' "see [app.txt:3](${gh_app}R3)" > "$draft"
o=$(verify github "$gh_url") || fail "a link on a changed non-blank line should pass: $o"
[ "$(val DEEP_LINK_SUSPECTS "$o")" = 0 ] || fail "expected 0 suspects, got: $o"
ok "verify: changed non-blank line -> clean"

printf '%s\n' "[a](${gh_app}R4) [b](${gh_app}R2) [c](${gh_app}R99)" > "$draft"
o=$(verify github "$gh_url") && fail "drifted links should exit non-zero: $o"
[ "$(val DEEP_LINK_SUSPECTS "$o")" = 3 ] || fail "expected 3 suspects, got: $o"
grep -q "^SUSPECT blank-line app.txt:4"      <<<"$o" || fail "missed the blank line: $o"
grep -q "^SUSPECT unchanged-line app.txt:2"  <<<"$o" || fail "missed the unchanged line: $o"
grep -q "^SUSPECT out-of-range app.txt:99"   <<<"$o" || fail "missed the out-of-range line: $o"
ok "verify: blank / unchanged / out-of-range each reported"

# A malformed line part questions the anchor's *shape*, which the four checks
# above take as given. `…#<hash>#L743` is what appending a familiar `#L<n>` to a
# prefix that already ends in `#<hash>` produces: two fragments, neither
# resolved, and the reader lands at the top of the diff.
printf '%s\n' "[x](${gh_app}#L743)" > "$draft"
o=$(verify github "$gh_url") && fail "a malformed line part should exit non-zero: $o"
grep -q "^SUSPECT malformed app.txt" <<<"$o" || fail "missed the malformed anchor: $o"
ok "verify: a second '#' fragment on a GitHub anchor is malformed"

printf '%s\n' "[x](${gl_app}#L743)" > "$draft"
o=$(verify gitlab "$gl_url") && fail "a malformed GitLab line part should exit non-zero: $o"
grep -q "^SUSPECT malformed app.txt" <<<"$o" || fail "missed the malformed GitLab anchor: $o"
ok "verify: the same malformation on a GitLab anchor"

printf '%s\n' "[a](${gh_app}R3) [b](${gh_app}L1) [c](${gh_app})" > "$draft"
o=$(verify github "$gh_url") || fail "R<n>, L<n>, and a bare prefix are all resolvable: $o"
ok "verify: R<n>, an old-side L<n>, and a bare file-level link all pass"

printf '%s\n' "[gone]($gh_url/changes#diff-$(ref_hash 256 nope.txt)R2)" > "$draft"
o=$(verify github "$gh_url") && fail "an anchor for an unchanged file should exit non-zero: $o"
grep -q "^SUSPECT unknown-file" <<<"$o" || fail "missed the unknown file: $o"
ok "verify: anchor matching no changed file -> unknown-file"

gl_prefix="$gl_app"
printf '%s\n' "[a](${gl_prefix}_3_3) [b](${gl_prefix}_4_4)" > "$draft"
o=$(verify gitlab "$gl_url") && fail "gitlab drift should exit non-zero: $o"
[ "$(val DEEP_LINK_SUSPECTS "$o")" = 1 ] || fail "expected 1 suspect, got: $o"
grep -q "^SUSPECT blank-line app.txt:4" <<<"$o" || fail "gitlab: missed the blank line: $o"
ok "verify: gitlab _<old>_<new> form checks the new line"

# --- A dirty tree makes every content read unreliable, in every mode ----------
printf '%s\n' "see [app.txt:3](${gh_app}R3)" > "$draft"
printf 'a1\nsettled\nchanged\n\na5\nlocal-edit\n' > "$repo/app.txt"
o=$(verify github "$gh_url" 2>/dev/null) || true
grep -q '^DEEP_LINK_TREE=dirty' <<<"$o" || fail "a dirty tree should be called out: $o"
o=$(run --check "$draft" --base main 2>/dev/null) || true
grep -q '^DEEP_LINK_TREE=dirty' <<<"$o" || fail "--check should call out a dirty tree too: $o"
git -C "$repo" checkout --quiet -- app.txt
o=$(verify github "$gh_url")
grep -q '^DEEP_LINK_TREE=' <<<"$o" && fail "a clean tree should say nothing about it: $o"
ok "dirty tree flagged, clean tree silent"

echo "# all checks passed"
