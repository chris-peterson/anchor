#!/usr/bin/env bash
# Functional test for scripts/merge.sh.
#
# Drives the real script against stub `gh` / `glab` whose merge moves a bare
# origin's target branch the way the forge would, so the cleanup that follows
# runs real `git checkout`, `pull --ff-only`, and `branch -d` against it.
#
# The cases worth pinning: the merge carries the head-SHA guard and deletes the
# source branch on both forges; a squash lands under a new SHA, which -d can't
# see and the forge's confirmation settles; and a refused merge announces
# nothing and leaves the checkout where it was.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
merge_sh="$here/../scripts/merge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$out"; }
expect() { [[ "$(val "$1")" == "$2" ]] || fail "$3: $1 was '$(val "$1")', expected '$2'"$'\n'"$out"; }

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-merge-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# Both stubs land the merge on $BARE's main — the head itself for a merge, a
# fresh commit with the head's tree for a squash — unless $FAIL_MERGE holds the
# error to refuse with. The landed sha is what the read-back reports.
cat > "$bin/land" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
head=$(git --git-dir="$BARE" rev-parse refs/heads/feature)
if [[ "$1" == squash ]]; then
  tree=$(git --git-dir="$BARE" rev-parse "$head^{tree}")
  landed=$(git --git-dir="$BARE" commit-tree "$tree" -p refs/heads/main -m squashed)
else
  landed="$head"
fi
git --git-dir="$BARE" update-ref refs/heads/main "$landed"
git --git-dir="$BARE" update-ref -d refs/heads/feature
printf '%s' "$landed" > "$LANDED"
EOF

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    [[ -z "$FAIL_MERGE" ]] || { echo "$FAIL_MERGE" >&2; exit 1; }
    case " $* " in *" --squash "*) land squash ;; *) land merge ;; esac ;;
  "pr view")
    jq -n --arg sha "$(cat "$LANDED")" '{url: "https://github.com/acme/widget/pull/128",
      title: "Widen the widget", state: "MERGED", mergedAt: "2026-09-29T15:37:54Z",
      mergeCommit: {oid: $sha}, baseRefName: "main", headRefName: "feature"}' ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
EOF

cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "glab $*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
  "mr merge")
    [[ -z "$FAIL_MERGE" ]] || { echo "$FAIL_MERGE" >&2; exit 1; }
    case " $* " in *" --squash "*) land squash ;; *) land merge ;; esac ;;
  "mr view")
    jq -n --arg sha "$(cat "$LANDED")" '{web_url: "https://gitlab.example.com/g/widget/-/merge_requests/42",
      title: "Widen the widget", state: "merged", merged_at: "2026-09-29T15:37:54Z",
      merge_commit_sha: $sha, target_branch: "main", source_branch: "feature"}' ;;
  *) echo "stub glab: unhandled: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/land" "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"

CALL_LOG="$work/calls.log"
LANDED="$work/landed"
FAIL_MERGE=""
export CALL_LOG LANDED FAIL_MERGE

# setup <host> — a bare origin whose path names the forge (the forge is read off
# the remote URL), and a checkout on a pushed feature branch.
setup() {
  rm -rf "$work/origin" "$work/repo"
  BARE="$work/origin/$1/acme/widget.git"
  export BARE
  mkdir -p "$BARE"
  git init --quiet --bare -b main "$BARE"
  repo="$work/repo"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  # The stub's squash writes a commit in the bare repo, which reads no identity
  # from the checkout; a runner with no fallback identity refuses it.
  git --git-dir="$BARE" config user.email t@example.com
  git --git-dir="$BARE" config user.name T
  git -C "$repo" remote add origin "$BARE"
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m seed
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" checkout --quiet -b feature
  printf 'change\n' >> "$repo/README.md"
  git -C "$repo" commit --quiet -am change
  git -C "$repo" push --quiet -u origin feature
  head=$(git -C "$repo" rev-parse HEAD)
}

run() {
  : > "$CALL_LOG"
  out=""; status=0
  out="$(bash "$merge_sh" --repo "$repo" "$@" 2>&1)" || status=$?
}

# --- GitHub, merge commit -----------------------------------------------------
setup github.com
run --cr 128 --sha "$head" --method merge
[[ "$status" == 0 ]] || fail "merge exited $status: $out"
grep -q -- "gh pr merge 128 --merge --delete-branch --match-head-commit $head" "$CALL_LOG" \
  || fail "merge not guarded on the head: $(cat "$CALL_LOG")"
expect MERGED ok "merged"
expect MERGE_SHA "$head" "landed sha read back"
expect TARGET_BRANCH main "target"
expect CLEANUP ok "cleanup"
grep -q '^codes.bridgeai.anchor/cr.merged ' <<<"$out" || fail "no cr.merged announcement"$'\n'"$out"
[[ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" == main ]] || fail "checkout not on main"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$head" ]] || fail "main not pulled"
! git -C "$repo" show-ref --verify --quiet refs/heads/feature || fail "feature branch left behind"
ok "github: merge is guarded on the head, announced, and cleaned up"

# --- GitHub, squash: -d refuses, the forge's confirmation settles it -----------
setup github.com
run --cr 128 --sha "$head" --method squash --squash 1
[[ "$status" == 0 ]] || fail "squash exited $status: $out"
grep -q -- "--squash" "$CALL_LOG" || fail "squash flag missing: $(cat "$CALL_LOG")"
expect CLEANUP ok "squash cleanup"
[[ "$(val MERGE_SHA)" != "$head" ]] || fail "squash should land a new sha"
! git -C "$repo" show-ref --verify --quiet refs/heads/feature || fail "squashed branch left behind"
ok "github: a squashed branch is deleted after the forge confirms the merge"

# --- GitHub, refused on auth --------------------------------------------------
setup github.com
FAIL_MERGE="HTTP 401: Bad credentials" run --cr 128 --sha "$head" --method merge
[[ "$status" == 70 ]] || fail "auth refusal exited $status: $out"
grep -q '^MERGE_AUTH=1' <<<"$out" || fail "auth not flagged"$'\n'"$out"
! grep -q 'cr.merged' <<<"$out" || fail "announced a merge that didn't happen"
[[ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" == feature ]] || fail "checkout moved on a refused merge"
ok "github: a refused merge announces nothing and leaves the checkout alone"

# --- GitHub, a merge -d can't see is reported, not forced ----------------------
setup github.com
git -C "$repo" commit --quiet --allow-empty -m "local only"
run --cr 128 --sha "$head" --method merge
expect CLEANUP incomplete "unmerged local commit"
git -C "$repo" show-ref --verify --quiet refs/heads/feature || fail "forced a delete -d refused"
ok "github: a branch -d refuses on a merge commit is kept and reported"

# --- GitLab -------------------------------------------------------------------
setup gitlab.example.com
run --cr 42 --sha "$head" --method ff
[[ "$status" == 0 ]] || fail "gitlab merge exited $status: $out"
grep -q -- "glab mr merge 42 --remove-source-branch --sha $head --yes --auto-merge=false" "$CALL_LOG" \
  || fail "gitlab merge flags: $(cat "$CALL_LOG")"
! grep -q -- "--squash" "$CALL_LOG" || fail "squashed without being asked"
expect CLEANUP ok "gitlab cleanup"
ok "gitlab: merge is guarded, removes the source branch, and turns off auto-merge"

setup gitlab.example.com
run --cr 42 --sha "$head" --method merge --squash 1
grep -q -- "--squash" "$CALL_LOG" || fail "squash flag missing: $(cat "$CALL_LOG")"
expect CLEANUP ok "gitlab squash cleanup"
ok "gitlab: --squash 1 squashes"

echo "PASS"
