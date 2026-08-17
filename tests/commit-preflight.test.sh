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

run() { ( cd "$repo" && bash "$preflight" "$@" ); }

# --- feature branch, staged change, unpushed ------------------------------
git -C "$repo" checkout --quiet -b feat
printf 'change\n' > "$repo/a.txt"
o=$(run --path a.txt)
[ "$(val STAGED "$o")" = 1 ]              || fail "STAGED should be 1"
[ -n "$(val STAT "$o")" ]                 || fail "STAT should be non-empty"
# REPO_ROOT saves the skill a `git rev-parse --show-toplevel` call (UX-05).
# Compared against git's own answer, not $repo: mktemp hands back a path through
# a symlink on macOS, so the raw string wouldn't match the resolved one.
[ "$(val REPO_ROOT "$o")" = "$(git -C "$repo" rev-parse --show-toplevel)" ] \
  || fail "REPO_ROOT should be the resolved checkout; got $(val REPO_ROOT "$o")"
[ "$(val BRANCH "$o")" = feat ]           || fail "BRANCH=feat"
[ "$(val DEFAULT_BRANCH "$o")" = main ]   || fail "DEFAULT_BRANCH=main"
[ "$(val ON_DEFAULT_BRANCH "$o")" = 0 ]   || fail "ON_DEFAULT_BRANCH=0 on feat"
grep -q '^SQUASH=' <<<"$o"                || fail "SQUASH line present (from squash-check)"
[ "$(val ANCHOR_CONFIG "$o")" = '{}' ]    || fail "ANCHOR_CONFIG should be {} with no keys; got $(val ANCHOR_CONFIG "$o")"
ok "feature branch + staged change: block populated, ON_DEFAULT_BRANCH=0"

# --- staging is path-scoped, never the whole tree --------------------------
# The trap this closes: a checkout shared with another agent session, whose
# in-flight file a `git add -A` would stage, review, and commit under this
# session's message.
git -C "$repo" reset --quiet
printf 'theirs\n' > "$repo/other-session.txt"
o=$(run --path a.txt)
git -C "$repo" diff --cached --name-only | grep -qx 'a.txt' || fail "--path a.txt should be staged"
if git -C "$repo" diff --cached --name-only | grep -qx 'other-session.txt'; then
  fail "an unnamed path must not be staged"
fi
[ "$(val OTHER_STAGED "$o")" = 0 ] || fail "OTHER_STAGED=0 when only our path is staged"
ok "staging: only --path is staged, the rest of the tree is left alone"

# someone else's file already in the index is reported, not swept into the stat
git -C "$repo" add other-session.txt
o=$(run --path a.txt)
[ "$(val OTHER_STAGED "$o")" = 1 ] \
  || fail "OTHER_STAGED should count the foreign staged path; got $(val OTHER_STAGED "$o")"
ok "staging: a staged path we did not stage is reported as OTHER_STAGED"

# no --path stages nothing at all
git -C "$repo" reset --quiet
o=$(run)
[ "$(val STAGED "$o")" = 0 ] || fail "no --path should stage nothing; got STAGED=$(val STAGED "$o")"
ok "staging: with no --path nothing is staged"

# a path with nothing to stage is an error, not a silent drop
rc=0; out=$( run --path nonexistent.txt 2>&1 ) || rc=$?
[ "$rc" -eq 65 ] || fail "unchanged --path -> want exit 65, got $rc: $out"
grep -q 'names nothing changed' <<<"$out" || fail "want the nothing-changed error, got: $out"
ok "staging: a --path with nothing to stage exits 65"

# an absolute path is refused rather than resolved against the root
rc=0; out=$( run --path "$repo/a.txt" 2>&1 ) || rc=$?
[ "$rc" -eq 64 ] || fail "absolute --path -> want exit 64, got $rc: $out"
ok "staging: an absolute --path is refused"

git -C "$repo" add a.txt

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
