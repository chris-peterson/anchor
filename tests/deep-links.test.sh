#!/usr/bin/env bash
# Functional test for scripts/deep-links.sh — the per-file deep-link prefixes the
# CR description's Review guide points at. Asserts the forge-specific hash and
# view path, and that the hashes match what the forges actually render:
# GitLab anchors a file by sha1(path), GitHub by sha256(path).
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
links="$here/../scripts/deep-links.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

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
printf 'a1\na2\na3\na4\na5\n' > "$repo/app.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m seed
git -C "$repo" checkout --quiet -b feat
mkdir -p "$repo/src"
printf 'one\n' > "$repo/src/cli.ts"
printf 'two\n' > "$repo/docs.md"
# Line 3 changed and line 4 blanked, so app.txt carries a changed non-blank line,
# a changed blank line, and untouched lines — one file covering every verdict.
printf 'a1\na2\nchanged\n\na5\n' > "$repo/app.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m change

run() { ( cd "$repo" && bash "$links" "$@" ); }

# Reference hashes for src/cli.ts, computed independently of the script.
sha1_cli=$(printf '%s' src/cli.ts | shasum -a 1   | cut -d' ' -f1)
sha256_cli=$(printf '%s' src/cli.ts | shasum -a 256 | cut -d' ' -f1)

# --- GitHub: sha256 anchor on the /changes view -------------------------------
o=$(run --forge github --cr-url https://github.com/o/r/pull/32 --base main)
j=$(val FILE_LINKS "$o")
[ "$(jq -r '."src/cli.ts"' <<<"$j")" = "https://github.com/o/r/pull/32/changes#diff-${sha256_cli}" ] \
  || fail "github prefix wrong: $(jq -r '."src/cli.ts"' <<<"$j")"
ok "github: /changes + sha256(path)"
[ "$(jq -r 'length' <<<"$j")" = 3 ] || fail "expected every changed file, got $(jq -c . <<<"$j")"
ok "github: every changed file present"

# --- GitLab: sha1 anchor on the /diffs view -----------------------------------
o=$(run --forge gitlab --cr-url https://gitlab.com/g/p/-/merge_requests/7 --base main)
j=$(val FILE_LINKS "$o")
[ "$(jq -r '."src/cli.ts"' <<<"$j")" = "https://gitlab.com/g/p/-/merge_requests/7/diffs#${sha1_cli}" ] \
  || fail "gitlab prefix wrong: $(jq -r '."src/cli.ts"' <<<"$j")"
ok "gitlab: /diffs + sha1(path)"

# --- The empty cases ----------------------------------------------------------
[ "$(val FILE_LINKS "$(run --forge none --cr-url '' --base main)")" = '{}' ] \
  || fail "forge=none should emit {}"
ok "forge=none -> {}"
[ "$(val FILE_LINKS "$(run --forge github --cr-url '' --base main)")" = '{}' ] \
  || fail "missing CR URL should emit {} (skip-deep-links path)"
ok "no CR URL -> {}"
[ "$(val FILE_LINKS "$(run --forge github --cr-url https://x/pull/1 --base feat)")" = '{}' ] \
  || fail "range with no changed files should emit {}"
ok "no changed files -> {}"

# --- --verify: the line part, the half the prefix derivation doesn't cover -----
gh_url=https://github.com/o/r/pull/32
app_prefix="$gh_url/changes#diff-$(printf '%s' app.txt | shasum -a 256 | cut -d' ' -f1)"
draft="$work/draft.md"

verify() { ( cd "$repo" && bash "$links" --verify "$draft" --forge "$1" --cr-url "$2" --base main ); }

printf '%s\n' "see [app.txt:3](${app_prefix}R3)" > "$draft"
o=$(verify github "$gh_url") || fail "a link on a changed non-blank line should pass: $o"
[ "$(val DEEP_LINK_SUSPECTS "$o")" = 0 ] || fail "expected 0 suspects, got: $o"
ok "verify: changed non-blank line -> clean"

printf '%s\n' "[a](${app_prefix}R4) [b](${app_prefix}R1) [c](${app_prefix}R99)" > "$draft"
o=$(verify github "$gh_url") && fail "drifted links should exit non-zero: $o"
[ "$(val DEEP_LINK_SUSPECTS "$o")" = 3 ] || fail "expected 3 suspects, got: $o"
grep -q "^SUSPECT blank-line app.txt:4"      <<<"$o" || fail "missed the blank line: $o"
grep -q "^SUSPECT unchanged-line app.txt:1"  <<<"$o" || fail "missed the unchanged line: $o"
grep -q "^SUSPECT out-of-range app.txt:99"   <<<"$o" || fail "missed the out-of-range line: $o"
ok "verify: blank / unchanged / out-of-range each reported"

printf '%s\n' "[gone]($gh_url/changes#diff-$(printf '%s' nope.txt | shasum -a 256 | cut -d' ' -f1)R2)" > "$draft"
o=$(verify github "$gh_url") && fail "an anchor for an unchanged file should exit non-zero: $o"
grep -q "^SUSPECT unknown-file" <<<"$o" || fail "missed the unknown file: $o"
ok "verify: anchor matching no changed file -> unknown-file"

printf '%s\n' "file-level [app.txt](${app_prefix})" > "$draft"
o=$(verify github "$gh_url") || fail "a bare file-level prefix has no line part to check: $o"
ok "verify: bare file-level prefix -> clean"

printf '%s\n' "see [app.txt:3](${app_prefix}R3)" > "$draft"
printf 'a1\na2\nchanged\n\na5\nlocal-edit\n' > "$repo/app.txt"
o=$(verify github "$gh_url" 2>/dev/null) || true
grep -q '^DEEP_LINK_TREE=dirty' <<<"$o" || fail "a dirty tree should be called out: $o"
git -C "$repo" checkout --quiet -- app.txt
o=$(verify github "$gh_url")
grep -q '^DEEP_LINK_TREE=' <<<"$o" && fail "a clean tree should say nothing about it: $o"
ok "verify: dirty tree flagged, clean tree silent"

gl_url=https://gitlab.com/g/p/-/merge_requests/7
gl_prefix="$gl_url/diffs#$(printf '%s' app.txt | shasum -a 1 | cut -d' ' -f1)"
printf '%s\n' "[a](${gl_prefix}_3_3) [b](${gl_prefix}_4_4)" > "$draft"
o=$(verify gitlab "$gl_url") && fail "gitlab drift should exit non-zero: $o"
[ "$(val DEEP_LINK_SUSPECTS "$o")" = 1 ] || fail "expected 1 suspect, got: $o"
grep -q "^SUSPECT blank-line app.txt:4" <<<"$o" || fail "gitlab: missed the blank line: $o"
ok "verify: gitlab _<old>_<new> form checks the new line"

echo "# all checks passed"
