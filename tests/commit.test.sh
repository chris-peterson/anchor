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

# What the review would print as REVIEW_INDEX for these paths.
digest() { ( cd "$repo" && source "$here/../scripts/lib/stage-paths.sh" && anchor_index_digest "$@" ); }

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
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" --force-with-lease \
        --reviewed-index "$(digest b.txt)" --path b.txt)
echo "$out" | grep -q '^PUSH_MODE=force-with-lease$' || fail "expected force-with-lease; got: $out"
git -C "$repo" show HEAD:b.txt | grep -qx 'more feature' || fail "the squash did not carry the staged change"
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
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
        --reviewed-index "$(digest mine.txt)" --path mine.txt)
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
git -C "$repo" add mine.txt
printf 'Add mine only (amended)\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" \
        --force-with-lease --reviewed-index "$(digest mine.txt)" --path mine.txt)
echo "$out" | grep -q '^PUSHED=ok$' || fail "scoped amend push not ok: $out"
git -C "$repo" ls-tree --name-only HEAD | grep -qx 'seed.txt' || fail "scoped amend dropped seed.txt from the tree"
git -C "$repo" ls-tree --name-only HEAD | grep -qx 'mine.txt' || fail "scoped amend lost mine.txt"
if git -C "$repo" show --name-only --format= HEAD | grep -qx 'other-session.txt'; then
  fail "scoped amend pulled in the other session's file"
fi
ok "--path amend keeps the amended commit's other files and still excludes foreign work"

# --- --path commits the index, not the working tree --------------------------
# A partly staged file: the staged hunks are the reviewed changeset, and the
# unstaged ones were left out on purpose. `git commit -- <path>` would take the
# working-tree copy and carry them in.
printf 'line one\nline two\n' > "$repo/partial.txt"
git -C "$repo" add partial.txt
printf 'Seed partial\n' > "$msgfile"
bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
  --reviewed-index "$(digest partial.txt)" --path partial.txt >/dev/null
printf 'LINE ONE\nline two\n' > "$repo/partial.txt"
git -C "$repo" add partial.txt
printf 'LINE ONE\nline two\nleft out\n' > "$repo/partial.txt"
printf 'Capitalize line one\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
        --reviewed-index "$(digest partial.txt)" --path partial.txt)
echo "$out" | grep -q '^PUSHED=ok$' || fail "partly staged commit push not ok: $out"
[[ "$(git -C "$repo" show HEAD:partial.txt)" == "$(printf 'LINE ONE\nline two')" ]] \
  || fail "commit carried unstaged hunks: $(git -C "$repo" show HEAD:partial.txt)"
[[ "$(cat "$repo/partial.txt")" == "$(printf 'LINE ONE\nline two\nleft out')" ]] \
  || fail "the unstaged hunk should still be in the working tree"
git -C "$repo" diff --quiet --cached -- partial.txt \
  || fail "the committed hunk should no longer show as staged"
if git -C "$repo" show --name-only --format= HEAD | grep -qx 'other-session.txt'; then
  fail "partly staged commit swept in the other session's file"
fi
git -C "$repo" diff --cached --name-only | grep -qx 'other-session.txt' \
  || fail "the other session's staged file should still be staged"
ok "--path commits a partly staged file's staged hunks and leaves the rest unstaged"

# a staged deletion under --path is committed as a deletion
git -C "$repo" rm --quiet --force partial.txt
printf 'Remove partial\n' > "$msgfile"
bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
  --reviewed-index "$(digest partial.txt)" --staged-path partial.txt >/dev/null
if git -C "$repo" ls-tree --name-only HEAD | grep -qx 'partial.txt'; then
  fail "a staged deletion under --path was not committed"
fi
ok "--path commits a staged deletion"

# --- naming a rename's new name commits both halves (#116) -------------------
git -C "$repo" mv mine.txt mine-renamed.txt
printf 'Rename mine\n' > "$msgfile"
bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
  --reviewed-index "$(digest mine-renamed.txt mine.txt)" --path mine-renamed.txt >/dev/null
tree=$(git -C "$repo" ls-tree --name-only HEAD)
grep -qx 'mine-renamed.txt' <<<"$tree" || fail "the rename's new name should be committed"
! grep -qx 'mine.txt' <<<"$tree" || fail "the rename's old name should be gone from the tree"
! git -C "$repo" diff --cached --name-only | grep -qx 'mine.txt' || fail "the rename's delete should not be left staged"
ok "--path naming a rename's new name commits the delete with it"

# --- --reviewed-index commits only the index the review showed ------------------
# The commit reads the index when it runs, so a `git add` after the review would
# otherwise ship unreviewed (COMMIT-04e).
printf 'reviewed\n' > "$repo/pinned.txt"
git -C "$repo" add pinned.txt
reviewed=$(digest pinned.txt)
printf 'reviewed\nstaged after the review\n' > "$repo/pinned.txt"
git -C "$repo" add pinned.txt
sha_before=$(git -C "$repo" rev-parse HEAD)
printf 'Add pinned\n' > "$msgfile"
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
        --reviewed-index "$reviewed" --path pinned.txt 2>&1)
rc=$?
set -e
[[ $rc -eq 68 ]] || fail "index changed after review -> want exit 68, got $rc: $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$sha_before" ]] || fail "a changed index still committed"
git -C "$repo" diff --cached --name-only | grep -qx 'pinned.txt' || fail "the refused path should stay staged"
ok "--reviewed-index refuses (exit 68) when the index changed after the review"

out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
        --reviewed-index "$(digest pinned.txt)" --path pinned.txt)
echo "$out" | grep -q '^PUSHED=ok$' || fail "matching --reviewed-index push not ok: $out"
[[ "$(git -C "$repo" show HEAD:pinned.txt)" == "$(printf 'reviewed\nstaged after the review')" ]] \
  || fail "matching --reviewed-index committed the wrong content"
ok "--reviewed-index commits when the index matches the review"

# a --path with no --reviewed-index is refused: a tree change is always reviewed
printf 'unreviewed\n' > "$repo/unreviewed.txt"
git -C "$repo" add unreviewed.txt
sha_before=$(git -C "$repo" rev-parse HEAD)
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" --path unreviewed.txt 2>&1)
rc=$?
set -e
[[ $rc -eq 64 ]] || fail "--path without --reviewed-index -> want exit 64, got $rc: $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$sha_before" ]] || fail "--path without --reviewed-index still committed"
git -C "$repo" reset --quiet -- unreviewed.txt
rm -f "$repo/unreviewed.txt"
ok "--path without --reviewed-index is refused before anything is committed"

# --- a message-only amend leaves a foreign staged path out ------------------
# No paths means no tree change: the amend rewrites the message, and another
# session's staged file stays staged rather than riding into it (COMMIT-04b).
printf 'staged by a peer\n' > "$repo/peer-amend.txt"
git -C "$repo" add peer-amend.txt
tree_before=$(git -C "$repo" rev-parse 'HEAD^{tree}')
printf 'Reword the last message\n' > "$msgfile"
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" --force-with-lease)
echo "$out" | grep -q '^PUSHED=ok$' || fail "message-only amend push not ok: $out"
[[ "$(git -C "$repo" rev-parse 'HEAD^{tree}')" == "$tree_before" ]] \
  || fail "a message-only amend changed the tree: $(git -C "$repo" show --name-only --format= HEAD)"
[[ "$(git -C "$repo" log -1 --format=%s)" == "Reword the last message" ]] || fail "the message was not amended"
git -C "$repo" diff --cached --name-only | grep -qx 'peer-amend.txt' || fail "the peer's file should still be staged"
git -C "$repo" reset --quiet -- peer-amend.txt
rm -f "$repo/peer-amend.txt"
ok "a message-only amend keeps a foreign staged path out of the commit"

# --- a hook that changes the commit stops it before the push (#79) -----------
# A pre-commit hook runs against the index the commit is built from, so a hook
# that stages a file would land it unreviewed. The commit stays local and the
# script names what the hook changed.
cat > "$repo/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
printf 'formatted\n' > hooked.txt
git add hooked.txt
HOOK
chmod +x "$repo/.git/hooks/pre-commit"
printf 'reviewed only\n' > "$repo/hook-target.txt"
git -C "$repo" add hook-target.txt
remote_before=$(git -C "$remote" rev-parse refs/heads/feat)
printf 'Add hook target\n' > "$msgfile"
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
        --reviewed-index "$(digest hook-target.txt)" --path hook-target.txt 2>&1)
rc=$?
set -e
rm -f "$repo/.git/hooks/pre-commit"
[[ $rc -eq 71 ]] || fail "a hook-changed commit -> want exit 71, got $rc: $out"
grep -q 'hooked.txt' <<<"$out" || fail "the refusal should name the path the hook changed: $out"
[[ "$(git -C "$remote" rev-parse refs/heads/feat)" == "$remote_before" ]] || fail "a hook-changed commit was pushed"
git -C "$repo" reset --quiet --hard HEAD~1
rm -f "$repo/hooked.txt"
ok "a commit a git hook changed after the review stops before the push (exit 71)"

# --- the squash gate is read again where the amend runs ----------------------
# The flow reads it at the start, and HEAD can stop being amendable before the
# commit step (a CR marked ready). A HEAD someone else authored is the case a
# local repo can stage: the author guard closes the gate (RULE-05).
printf 'theirs\n' > "$repo/theirs.txt"
git -C "$repo" add theirs.txt
git -C "$repo" -c user.name=Other -c user.email=other@example.com commit --quiet -m "Their commit"
sha_before=$(git -C "$repo" rev-parse HEAD)
printf 'Reword their commit\n' > "$msgfile"
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode amend --message-file "$msgfile" --force-with-lease 2>&1)
rc=$?
set -e
[[ $rc -eq 69 ]] || fail "an amend the gate refuses -> want exit 69, got $rc: $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$sha_before" ]] || fail "a refused amend still rewrote HEAD"
ok "an amend is refused (exit 69) when the squash gate no longer allows it"

# an absolute --path is refused before anything is committed
sha_before=$(git -C "$repo" rev-parse HEAD)
set +e
out=$(bash "$commit_sh" --repo "$repo" --mode new --message-file "$msgfile" \
        --reviewed-index unused --path "$repo/mine.txt" 2>&1)
rc=$?
set -e
[[ $rc -eq 64 ]] || fail "absolute --path -> want exit 64, got $rc: $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$sha_before" ]] || fail "absolute --path still committed"
ok "an absolute --path is refused before anything is committed"

echo "# all checks passed"
