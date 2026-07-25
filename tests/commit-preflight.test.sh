#!/usr/bin/env bash
# Functional test for scripts/commit-preflight.sh — the /anchor:commit recon
# aggregator. Asserts the single KEY=value block it emits (staging, stat,
# branch/default, ahead-count, squash gate, anchor config).
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preflight="$here/../scripts/commit-preflight.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-preflight-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

remote="$work/remote.git"; repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false
printf 'seed\n' > "$repo/seed.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m seed
git init --quiet --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push --quiet -u origin main
git -C "$repo" remote set-head origin main

run() { ( cd "$repo" && bash "$preflight" ); }

# --- feature branch, staged change, unpushed ------------------------------
git -C "$repo" checkout --quiet -b feat
printf 'change\n' > "$repo/a.txt"
o=$(run)
[ "$(val STAGED "$o")" = 1 ]              || fail "STAGED should be 1"
[ -n "$(val STAT "$o")" ]                 || fail "STAT should be non-empty"
[ "$(val BRANCH "$o")" = feat ]           || fail "BRANCH=feat"
[ "$(val DEFAULT_BRANCH "$o")" = main ]   || fail "DEFAULT_BRANCH=main"
[ "$(val ON_DEFAULT_BRANCH "$o")" = 0 ]   || fail "ON_DEFAULT_BRANCH=0 on feat"
grep -q '^SQUASH=' <<<"$o"                || fail "SQUASH line present (from squash-check)"
[ "$(val ANCHOR_CONFIG "$o")" = '{}' ]    || fail "ANCHOR_CONFIG should be {} with no keys; got $(val ANCHOR_CONFIG "$o")"
ok "feature branch + staged change: block populated, ON_DEFAULT_BRANCH=0"

# --- anchor.* config surfaces as JSON -------------------------------------
git -C "$repo" config anchor.reviewBudgetMins 5
o=$(run)
[ "$(jq -r '."anchor.reviewbudgetmins"' <<<"$(val ANCHOR_CONFIG "$o")")" = 5 ] \
  || fail "ANCHOR_CONFIG should carry anchor.reviewBudgetMins; got $(val ANCHOR_CONFIG "$o")"
ok "anchor.* keys surface in ANCHOR_CONFIG"
git -C "$repo" config --unset anchor.reviewBudgetMins

# --- on default branch, nothing new staged --------------------------------
git -C "$repo" checkout --quiet -f main
git -C "$repo" reset --hard --quiet origin/main
git -C "$repo" clean -fdq
o=$(run)
[ "$(val ON_DEFAULT_BRANCH "$o")" = 1 ]   || fail "ON_DEFAULT_BRANCH=1 on main"
[ "$(val STAGED "$o")" = 0 ]              || fail "STAGED=0 with nothing to stage"
[ -z "$(val STAT "$o")" ]                 || fail "STAT empty with nothing staged"
ok "on default branch, nothing staged: ON_DEFAULT_BRANCH=1, STAGED=0"

echo "# all checks passed"
