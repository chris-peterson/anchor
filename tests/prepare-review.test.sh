#!/usr/bin/env bash
# Functional test for scripts/prepare-review.sh's DELETE_BRANCH_ON_MERGE key.
#
# The key exists because the two forges carry the preference in different places:
# GitLab takes `remove_source_branch` per MR (so the create call sets it), while
# GitHub has no per-PR field at all — only the repo-wide `deleteBranchOnMerge`.
# A GitHub PR anchor opens therefore carries no preference, and the branch
# survives any merge that doesn't pass `--delete-branch`. The script reports the
# fact so the skill can name it instead of the user discovering the leftover
# branch after the merge.
#
# Drives the real script against a local bare remote and stub `gh` / `glab`
# binaries. The remote path embeds `github.com` / `gitlab.com` as a directory
# component because forge detection matches on the origin URL, and a rewrite via
# `url.<x>.insteadOf` doesn't work — `git remote get-url` reports the rewritten
# path, which would read as no forge at all.
set -euo pipefail

# Hermetic: ignore the user's global/system git config (hooks, templates, a
# global anchor.* key) so the test's behavior doesn't depend on the environment.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare_review_sh="$here/../scripts/prepare-review.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-prepare-review-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub gh: serves $CR_JSON (empty file == no PR open), installs
# --- $CR_AFTER_CREATE on `pr create`, and reports the repo-wide branch-deletion
# --- setting from $DELETE_ON_MERGE (`true` / `false` / `error` to fail the read).
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CALL_LOG"
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)   [[ -s "$CR_JSON" ]] || exit 1; cat "$CR_JSON" ;;
      create) cp "$CR_AFTER_CREATE" "$CR_JSON"
              echo "https://github.com/example/repo/pull/7" ;;
      *) echo "stub gh: unhandled pr subcommand: ${2:-}" >&2; exit 1 ;;
    esac ;;
  repo)
    case "${2:-}" in
      view) [[ "$DELETE_ON_MERGE" == error ]] && { echo "stub gh: repo view failed" >&2; exit 1; }
            printf '{"deleteBranchOnMerge":%s}\n' "$DELETE_ON_MERGE" ;;
      *) echo "stub gh: unhandled repo subcommand: ${2:-}" >&2; exit 1 ;;
    esac ;;
  *) echo "stub gh: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

# --- stub glab: same contract on the MR side; `api user` serves the username the
# --- create call assigns to.
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'glab %s\n' "$*" >> "$CALL_LOG"
case "${1:-}" in
  mr)
    case "${2:-}" in
      view)   [[ -s "$CR_JSON" ]] || exit 1; cat "$CR_JSON" ;;
      create) cp "$CR_AFTER_CREATE" "$CR_JSON"
              echo "https://gitlab.com/example/repo/-/merge_requests/7" ;;
      *) echo "stub glab: unhandled mr subcommand: ${2:-}" >&2; exit 1 ;;
    esac ;;
  api)
    case "${2:-}" in
      user) echo '{"username":"tester"}' ;;
      *) echo "stub glab: unhandled api path: ${2:-}" >&2; exit 1 ;;
    esac ;;
  *) echo "stub glab: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

chmod +x "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"

# Build a repo whose origin URL reads as <host>, on a pushed feature branch with
# one commit ahead of the default branch — the state the auto-open path needs.
# Echoes the repo path.
make_repo() {
  local host=$1 name=$2 remote repo
  remote="$work/remotes/$name/$host/example/repo.git"
  repo="$work/repos/$name"
  mkdir -p "$(dirname "$remote")" "$(dirname "$repo")"
  git init --quiet --bare "$remote"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "seed"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" remote set-head origin main
  git -C "$repo" checkout --quiet -b feat
  printf 'change\n' > "$repo/a.txt"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "Add a"
  git -C "$repo" push --quiet -u origin feat
  echo "$repo"
}

key() { sed -n "s/^$2=//p" <<<"$1"; }

export CALL_LOG="$work/calls.log"
export CR_JSON="$work/cr.json"
export CR_AFTER_CREATE="$work/cr-after-create.json"
export DELETE_ON_MERGE=false

gh_pr_json() {
  cat > "$CR_AFTER_CREATE" <<JSON
{"url":"https://github.com/example/repo/pull/7","number":7,"isDraft":true,
 "headRefOid":"$1","body":"seeded body"}
JSON
}

glab_mr_json() {
  cat > "$CR_AFTER_CREATE" <<JSON
{"web_url":"https://gitlab.com/example/repo/-/merge_requests/7","iid":7,"draft":true,
 "sha":"$1","description":"seeded body",
 "should_remove_source_branch":$2,"force_remove_source_branch":$3}
JSON
}

# --- GitHub, repo setting off: the opened PR carries no preference -----------
repo="$(make_repo github.com gh-off)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=false
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" CR_CREATED)" == 1 ]] || fail "expected the script to open the PR; got: $out"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == false ]] \
  || fail "expected DELETE_BRANCH_ON_MERGE=false with the repo setting off; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitHub with deleteBranchOnMerge off reports false"

# --- GitHub, repo setting on -------------------------------------------------
repo="$(make_repo github.com gh-on)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=true
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == true ]] \
  || fail "expected true with the repo setting on; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitHub with deleteBranchOnMerge on reports true"

# --- GitHub, the setting read fails: unknown, never a silent false -----------
repo="$(make_repo github.com gh-err)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=error
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == unknown ]] \
  || fail "expected unknown when the setting read fails; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitHub reports unknown when the repo-setting read fails"

# --- GitHub, the setting reads as null: unknown, and the block still lands ---
# A field GitHub answers as null (a permission that hides it, a schema change) is
# neither state. The whole KEY=value block has to survive it — the skill acts on
# the block, so a script that exits early takes the rest of the recon with it.
repo="$(make_repo github.com gh-null)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=null
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == unknown ]] \
  || fail "expected unknown for a null setting; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
[[ -n "$(key "$out" FILE_LINKS)" ]] || fail "block truncated after the null setting: $out"
ok "GitHub reports unknown for a null setting without truncating the block"

# --- GitLab: the create call still sets the per-MR flag ----------------------
repo="$(make_repo gitlab.com gl-create)"
: > "$CR_JSON"
: > "$CALL_LOG"
glab_mr_json "$(git -C "$repo" rev-parse HEAD)" true false
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" CR_CREATED)" == 1 ]] || fail "expected the script to open the MR; got: $out"
grep -q 'glab mr create .*--remove-source-branch' "$CALL_LOG" \
  || fail "create call dropped --remove-source-branch: $(cat "$CALL_LOG")"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == true ]] \
  || fail "expected true for an MR created with --remove-source-branch; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitLab sets --remove-source-branch at create and reports true"

# --- GitLab, a pre-existing MR with the flag unset --------------------------
repo="$(make_repo gitlab.com gl-unset)"
glab_mr_json "$(git -C "$repo" rev-parse HEAD)" false false
cp "$CR_AFTER_CREATE" "$CR_JSON"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" CR_PREEXISTING)" == 1 ]] || fail "expected the MR to resolve as pre-existing; got: $out"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == false ]] \
  || fail "expected false for an MR with the flag unset; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitLab reports false for a pre-existing MR with the flag unset"

# --- GitLab, project settings force the removal -----------------------------
repo="$(make_repo gitlab.com gl-forced)"
glab_mr_json "$(git -C "$repo" rev-parse HEAD)" false true
cp "$CR_AFTER_CREATE" "$CR_JSON"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == true ]] \
  || fail "expected true when force_remove_source_branch is set; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitLab reports true when the project forces branch removal"

# --- No forge: nothing to report -------------------------------------------
repo="$(make_repo example.invalid no-forge)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" FORGE)" == none ]] || fail "expected FORGE=none; got: $out"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == unknown ]] \
  || fail "expected unknown with no forge; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "no forge reports unknown"

echo "all prepare-review tests passed"
