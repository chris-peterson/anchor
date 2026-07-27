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
git -C "$repo" add -A
git -C "$repo" commit --quiet -m seed
git -C "$repo" checkout --quiet -b feat
mkdir -p "$repo/src"
printf 'one\n' > "$repo/src/cli.ts"
printf 'two\n' > "$repo/docs.md"
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
[ "$(jq -r 'length' <<<"$j")" = 2 ] || fail "expected both changed files, got $(jq -c . <<<"$j")"
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

echo "# all checks passed"
