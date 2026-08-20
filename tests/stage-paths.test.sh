#!/usr/bin/env bash
# Functional test for scripts/lib/stage-paths.sh (anchor_stage_paths).
#
# The behavior under test is idempotence across a repeated path list. The
# /anchor:commit flow stages the same --path list twice by design — once in
# commit-preflight.sh, again when review-diff.sh --local opens the review, which
# needs new files in the index before `git diff HEAD` will show them. A path git
# has already fully staged is no longer on disk under its own name when it was a
# deletion or the old half of a rename, and naming it in `git add` is fatal, so
# these cases are what separate "already staged" from the typo the exit-65 guard
# exists to catch.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/stage-paths.sh
source "$here/../scripts/lib/stage-paths.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-stage-paths-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false

# Distinct contents: identical bodies let git's rename detection pair unrelated
# files, which would make the assertions below describe a different changeset.
printf 'modify me\n'   > "$repo/mod.txt"
printf 'delete me\n'   > "$repo/del.txt"
printf 'rename me\n'   > "$repo/ren.txt"
printf 'leave me\n'    > "$repo/untouched.txt"
mkdir -p "$repo/dir"
printf 'dir a\n'       > "$repo/dir/a.txt"
printf 'dir b\n'       > "$repo/dir/b.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m seed

cd "$repo"

# anchor_stage_paths returns a nonzero status by contract, so each call is run
# through this rather than tripping `set -e`.
rc() { local r=0; anchor_stage_paths "test" "$@" || r=$?; printf '%s' "$r"; }
staged() { git diff --cached --name-only; }

# --- the reported failure: a deleted path staged twice ---------------------
rm mod.txt; printf 'modified\n' > mod.txt
rm del.txt
[ "$(rc mod.txt del.txt)" = 0 ] || fail "first call should stage a deletion"
[ "$(rc mod.txt del.txt)" = 0 ] || fail "second call with the same list must not fail"
[ "$(rc mod.txt del.txt)" = 0 ] || fail "third call must not fail either"
ok "a staged deletion survives a repeated path list"

# The review reads `git diff HEAD`, so the deletion has to be visible there.
git diff HEAD --name-status | grep -qx "D.*del\.txt" \
  || fail "the deletion should appear in git diff HEAD for the review"
ok "the deletion is visible to the review's git diff HEAD"

# --- a rename: git stages it as a delete plus an add ----------------------
# The old half fails on the *first* call, not the second — `git mv` has already
# staged both halves, so nothing named ren.txt is left in the index or on disk.
git mv ren.txt ren-new.txt
[ "$(rc ren.txt ren-new.txt)" = 0 ] || fail "a staged rename's halves should both be accepted"
[ "$(rc ren.txt ren-new.txt)" = 0 ] || fail "a staged rename must survive the repeated call"
ok "both halves of a staged rename are accepted"

# --- one unstageable path must not drop the rest of the list ---------------
# `git add` aborts the whole invocation on a single bad pathspec, so a deletion
# sharing a list with a pending change used to take that change down with it.
printf 'fresh\n' > added.txt
[ "$(rc del.txt added.txt)" = 0 ] || fail "a fully-staged path alongside a new one should succeed"
staged | grep -qx 'added.txt' || fail "added.txt should be staged despite del.txt being spent"
ok "an already-staged path does not drop the rest of the list"

# --- the typo guard, which is why the check exists ------------------------
[ "$(rc nope-typo.txt)" = 65 ]  || fail "a path naming nothing changed should exit 65"
[ "$(rc untouched.txt)" = 65 ]  || fail "an unchanged tracked path should exit 65"
ok "a path naming nothing changed still exits 65"

# A spent path in the list must not mask a typo elsewhere in it.
[ "$(rc del.txt nope-typo.txt)" = 65 ] || fail "a typo beside a spent path should still exit 65"
ok "a typo is still caught alongside an already-staged path"

[ "$(rc /etc/hosts)" = 64 ] || fail "an absolute path should exit 64"
ok "an absolute path is still refused with exit 64"

# --- nothing left to stage: the add is skipped, not attempted -------------
before="$(staged)"
[ "$(rc mod.txt del.txt)" = 0 ] || fail "an all-spent list should succeed"
[ "$(staged)" = "$before" ] || fail "an all-spent list should not change the index"
ok "a list with nothing left to stage succeeds and touches nothing"

[ "$(rc)" = 0 ] || fail "no paths at all should be a no-op"
ok "no paths given is a no-op"

# --- a directory pathspec reports one line per entry ----------------------
rm dir/a.txt
printf 'dir b changed\n' > dir/b.txt
[ "$(rc dir)" = 0 ] || fail "a directory pathspec should stage its entries"
staged | grep -qx 'dir/b.txt' || fail "dir/b.txt should be staged"
[ "$(rc dir)" = 0 ] || fail "a directory pathspec must survive the repeated call"
ok "a directory pathspec with a deleted entry survives the repeated call"

# --- the shared-checkout constraint the lib exists for --------------------
printf 'theirs\n' > other-session.txt
printf 'ours\n'   > ours.txt
[ "$(rc ours.txt)" = 0 ] || fail "naming our own path should succeed"
staged | grep -qx 'ours.txt' || fail "ours.txt should be staged"
if staged | grep -qx 'other-session.txt'; then
  fail "an unnamed path must never be staged"
fi
ok "only the named paths are staged, never the whole tree"

echo "# all checks passed"
