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
if echo "$out" | grep -q 'commit\.pushed'; then
  fail "announced a push that never happened: $out"
fi
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

# --- The push announces itself ---------------------------------------------
# The announcement follows the push rather than the commit, so what a subscriber
# hears is always something it can reach. This repo's origin is a local path, so
# the URI is empty; the remote shapes that do build one are in
# tests/forge-url.test.sh. Guarded on jq for the same reason announce.test.sh is:
# without it the publisher says so on stderr and emits nothing.
if command -v jq >/dev/null 2>&1; then
  ann=$(echo "$out" | grep '^codes\.bridgeai\.anchor/commit\.pushed ') \
    || fail "no commit.pushed announcement: $out"
  echo "$ann" | grep -q "\"sha\":\"$(git -C "$repo" rev-parse --short HEAD)\"" \
    || fail "announcement carries the wrong sha: $ann"
  echo "$ann" | grep -q '"branch":"feat"' || fail "wrong branch announced: $ann"
  echo "$ann" | grep -q '"uri":""' \
    || fail "built a URI for a remote that is not a forge: $ann"
  ok "the push announces commit.pushed with the sha and branch"
else
  echo "# jq is not on PATH; skipping the announcement check"
fi

# --- Amend + force-with-lease ---------------------------------------------
printf 'more feature\n' >> "$repo/b.txt"
git -C "$repo" add -A
printf 'Add b on feat (amended)\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" --force-with-lease)
echo "$out" | grep -q '^PUSH_MODE=force-with-lease$' || fail "expected force-with-lease; got: $out"
echo "$out" | grep -q '^PUSHED=ok$'                 || fail "amend push not ok: $out"
[[ "$(git -C "$repo" rev-list --count feat)" -eq 3 ]] || fail "amend changed the commit count (should stay 3: seed, a, b)"
[[ "$(git -C "$repo" log -1 --format=%s)" == "Add b on feat (amended)" ]] || fail "amend did not rewrite the message"
[[ "$(git -C "$repo" rev-parse HEAD)" != "$sha_after_new" ]] || fail "amend left HEAD at the pre-amend sha"
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

# --- --path scopes the commit, leaving a foreign staged file staged ---------
# The shared-checkout case: another session has its file in the index, and this
# commit must neither carry it nor drop it.
printf 'ours\n' > "$repo/mine.txt"
printf 'theirs\n' > "$repo/other-session.txt"
git -C "$repo" add -A
printf 'Add mine only\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" --path mine.txt)
echo "$out" | grep -q '^PUSHED=ok$' || fail "scoped commit push not ok: $out"
git -C "$repo" show --name-only --format= HEAD | grep -qx 'mine.txt' || fail "scoped commit missing mine.txt"
if git -C "$repo" show --name-only --format= HEAD | grep -qx 'other-session.txt'; then
  fail "scoped commit swept in the other session's file"
fi
git -C "$repo" diff --cached --name-only | grep -qx 'other-session.txt' \
  || fail "the other session's staged file should still be staged"
ok "--path commits only the named paths and leaves a foreign staged file staged"

# --- amend + --path keeps the files the amended commit already carried ------
# `git commit --amend -- <paths>` layers the named paths onto the existing
# commit rather than reducing it to them, so a scoped amend is not lossy.
printf 'more ours\n' >> "$repo/mine.txt"
printf 'Add mine only (amended)\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" \
        --force-with-lease --path mine.txt)
echo "$out" | grep -q '^PUSHED=ok$' || fail "scoped amend push not ok: $out"
git -C "$repo" ls-tree --name-only HEAD | grep -qx 'seed.txt' || fail "scoped amend dropped seed.txt from the tree"
git -C "$repo" ls-tree --name-only HEAD | grep -qx 'mine.txt' || fail "scoped amend lost mine.txt"
if git -C "$repo" show --name-only --format= HEAD | grep -qx 'other-session.txt'; then
  fail "scoped amend pulled in the other session's file"
fi
ok "--path amend keeps the amended commit's other files and still excludes foreign work"

# an absolute --path is refused before anything is committed
sha_before=$(git -C "$repo" rev-parse HEAD)
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" --path "$repo/mine.txt" 2>&1)
rc=$?
set -e
[[ $rc -eq 64 ]] || fail "absolute --path -> want exit 64, got $rc: $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$sha_before" ]] || fail "absolute --path still committed"
ok "an absolute --path is refused before anything is committed"

echo "# all checks passed"
