#!/usr/bin/env bash
# Functional test for scripts/commit.sh.
#
# Drives the real commit + push against a local bare remote, exercising the
# push-variant selection (set-upstream / plain / force-with-lease), the
# push-existing mode, and the default-branch guard. Runs on ubuntu / macOS /
# Windows-Git-Bash in CI.
set -euo pipefail

# Hermetic: ignore the user's global/system git config (hooks, templates, a
# global anchor.* key) so the test's behavior doesn't depend on the environment.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
commit_sh="$here/../scripts/commit.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-commit-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

remote="$work/remote.git"
repo="$work/repo"

git init --quiet -b main "$repo"
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
printf 'seed\n' > "$repo/seed.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "seed"

git init --quiet --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push --quiet -u origin main
git -C "$repo" remote set-head origin main   # sets refs/remotes/origin/HEAD -> main

msgfile="$work/msg.txt"

# --- Default-branch guard: refuses on main without the escape --------------
printf 'on main\n' > "$repo/a.txt"
git -C "$repo" add -A
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file <(printf 'nope\n') 2>/dev/null)
rc=$?
set -e
[[ $rc -eq 65 ]] || fail "expected exit 65 on default-branch guard, got $rc"
# nothing should have been committed
[[ "$(git -C "$repo" rev-list --count main)" -eq 1 ]] || fail "guard let a commit through"
ok "default-branch guard blocks a bare commit on main (exit 65)"

# --- Default-branch guard: allowed with --allow-default-branch -------------
printf 'Add a on main\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" --allow-default-branch)
echo "$out" | grep -q '^PUSH_MODE=plain$'   || fail "expected plain push on main with upstream; got: $out"
echo "$out" | grep -q '^PUSHED=ok$'         || fail "push did not report ok: $out"
[[ "$(git -C "$repo" rev-list --count main)" -eq 2 ]] || fail "commit not created on main"
[[ "$(git -C "$remote" rev-list --count main)" -eq 2 ]] || fail "commit not pushed to remote main"
ok "default-branch commit lands with --allow-default-branch (plain push)"

# --- New commit on a fresh feature branch: sets upstream -------------------
git -C "$repo" checkout --quiet -b feat
printf 'feature change\n' > "$repo/b.txt"
git -C "$repo" add -A
printf 'Add b on feat\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile")
echo "$out" | grep -q '^BRANCH=feat$'         || fail "wrong branch reported: $out"
echo "$out" | grep -q '^PUSH_MODE=set-upstream$' || fail "expected set-upstream on first push; got: $out"
echo "$out" | grep -q '^PUSHED=ok$'           || fail "feat push not ok: $out"
git -C "$remote" rev-parse --verify --quiet feat >/dev/null || fail "feat not pushed to remote"
sha_after_new=$(git -C "$repo" rev-parse HEAD)
ok "new commit on a feature branch sets upstream"

# --- Amend + force-with-lease ---------------------------------------------
printf 'more feature\n' >> "$repo/b.txt"
git -C "$repo" add -A
printf 'Add b on feat (amended)\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" --force-with-lease)
echo "$out" | grep -q '^PUSH_MODE=force-with-lease$' || fail "expected force-with-lease; got: $out"
echo "$out" | grep -q '^PUSHED=ok$'                 || fail "amend push not ok: $out"
[[ "$(git -C "$repo" rev-list --count feat)" -eq 3 ]] || fail "amend changed the commit count (should stay 3: seed, a, b)"
[[ "$(git -C "$repo" log -1 --format=%s)" == "Add b on feat (amended)" ]] || fail "amend did not rewrite the message"
[[ "$(git -C "$remote" log -1 refs/heads/feat --format=%s)" == "Add b on feat (amended)" ]] || fail "remote feat not force-updated"
ok "amend force-pushes with lease and rewrites HEAD in place"

# --- push-existing: pushes an already-made local commit, no new commit -----
printf 'committed directly\n' > "$repo/c.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "Add c directly"
sha_before=$(git -C "$repo" rev-parse HEAD)
out=$(bash "$commit_sh" --repo "$repo" --mode push-existing)
sha_after=$(git -C "$repo" rev-parse HEAD)
[[ "$sha_before" == "$sha_after" ]] || fail "push-existing created or amended a commit"
echo "$out" | grep -q '^PUSH_MODE=plain$' || fail "expected plain push for push-existing; got: $out"
echo "$out" | grep -q '^PUSHED=ok$'       || fail "push-existing not ok: $out"
[[ "$(git -C "$remote" log -1 refs/heads/feat --format=%s)" == "Add c directly" ]] || fail "push-existing did not reach remote"
ok "push-existing pushes the unpushed commit without making a new one"

echo "# all checks passed"
