#!/usr/bin/env bash
# Functional test for scripts/stack.sh.
#
# Drives the real script against a local bare remote holding a real stack of
# branches, with stub `gh` / `glab` serving the open-CR listing, the per-MR
# details GitLab's listing lacks, and the retarget call. The remote path embeds
# `github.com` / `gitlab.com` because forge detection matches on the origin URL.
#
# The stack: main <- a (#1) <- b (#2) <- c (#3), where #3 targets main though c
# was cut from b, which is the CR `show` has to draw under #2 and flag. #9 is
# someone else's, on main, and shows only with --all.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_sh="$here/../scripts/stack.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-stack-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "pr list") cat "$CR_LIST" ;;
  "pr view") f="$VIEW_DIR/$3.json"; [[ -s "$f" ]] || exit 1; cat "$f" ;;
  "pr edit") [[ "${EDIT_FAIL:-0}" == 1 ]] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
             echo "pr edit $3 $4 $5" >> "$EDIT_LOG" ;;
  "api user") printf '{"login":"%s"}\n' "$VIEWER_LOGIN" ;;
  *) echo "stub gh: unhandled command: $*" >&2; exit 1 ;;
esac
EOF
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "mr list") cat "$CR_LIST" ;;
  "mr view") f="$VIEW_DIR/$3.json"; [[ -s "$f" ]] || exit 1; cat "$f" ;;
  "mr update") echo "mr update $3 $4 $5" >> "$EDIT_LOG" ;;
  "api user") printf '{"username":"%s"}\n' "$VIEWER_LOGIN" ;;
  "api projects/:fullpath/merge_requests/"*)
    rest="${2#projects/:fullpath/merge_requests/}"
    case "$rest" in
      */approvals) cat "$MR_DIR/${rest%/approvals}-approvals.json" ;;
      *)           cat "$MR_DIR/$rest.json" ;;
    esac ;;
  *) echo "stub glab: unhandled command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"

export CR_LIST="$work/cr-list.json"
export VIEW_DIR="$work/views"
export MR_DIR="$work/mrs"
export EDIT_LOG="$work/edits.log"
export VIEWER_LOGIN=me
export EDIT_FAIL=0
mkdir -p "$VIEW_DIR" "$MR_DIR"

key() { sed -n "s/^$2=//p" <<<"$1"; }

run() {
  rc=0
  out="$(bash "$stack_sh" "$@" 2>&1)" || rc=$?
}

identity() {
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
  git -C "$1" config commit.gpgsign false
}

commit_file() {
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit --quiet -m "Change $2"
}

# make_repo <host>: main <- a <- b <- c, and z on main, every branch pushed.
make_repo() {
  local host=$1 remote repo
  remote="$work/remotes/$host/example/repo.git"
  repo="$work/repos/$host"
  mkdir -p "$(dirname "$remote")" "$(dirname "$repo")"
  git init --quiet --bare -b main "$remote"
  git init --quiet -b main "$repo"
  identity "$repo"
  commit_file "$repo" seed.txt
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" remote set-head origin main
  local prev=main br
  for br in a b c; do
    git -C "$repo" checkout --quiet -b "$br" "$prev"
    commit_file "$repo" "$br.txt"
    git -C "$repo" push --quiet -u origin "$br"
    prev=$br
  done
  git -C "$repo" checkout --quiet -b z main
  commit_file "$repo" z.txt
  git -C "$repo" push --quiet -u origin z
  git -C "$repo" checkout --quiet c
  echo "$repo"
}

sha() { git -C "$repo" rev-parse "$1"; }

# gh_cr <num> <head> <target> <draft> <author> <review> <merge> <checks>
gh_cr() {
  jq -cn --argjson n "$1" --arg h "$2" --arg t "$3" --argjson d "$4" --arg a "$5" \
    --arg r "$6" --arg m "$7" --arg c "$8" --arg s "$(sha "$2")" '{
      number: $n, title: ("Change " + $h), url: ("https://github.com/example/repo/pull/" + ($n | tostring)),
      headRefName: $h, headRefOid: $s, baseRefName: $t, isDraft: $d, author: {login: $a},
      reviewDecision: $r, mergeStateStatus: $m,
      statusCheckRollup: (if $c == "" then [] else [{status: "COMPLETED", conclusion: $c}] end)}'
}

gl_cr() {
  jq -cn --argjson n "$1" --arg h "$2" --arg t "$3" --argjson d "$4" --arg a "$5" --arg m "$6" --arg s "$(sha "$2")" '{
      iid: $n, title: ("Change " + $h), web_url: ("https://gitlab.com/example/repo/-/merge_requests/" + ($n | tostring)),
      source_branch: $h, sha: $s, target_branch: $t, draft: $d, author: {username: $a},
      detailed_merge_status: $m}'
}

# --- GitHub: show -------------------------------------------------------------------
repo=$(make_repo github.com)
{
  gh_cr 1 a main false me APPROVED CLEAN SUCCESS
  gh_cr 2 b a true me REVIEW_REQUIRED DRAFT ""
  gh_cr 3 c main true me "" DRAFT FAILURE
  gh_cr 9 z main false ana APPROVED CLEAN SUCCESS
} | jq -s . > "$CR_LIST"

run show --repo "$repo"
[[ $rc -eq 0 ]] || fail "show: exit $rc"$'\n'"$out"
tree=$(key "$out" TREE)
expected='#1 Change a ← mergeable now
└ #2 Change b (draft)
  └ #3 Change c (draft) · checks failing ⚠ targets main, stacked on #2 ← current branch'
[[ "$tree" == "$expected" ]] || fail "show: tree"$'\n'"got:"$'\n'"$tree"$'\n'"want:"$'\n'"$expected"
[[ "$(key "$out" STACK_ORDER)" == "#1,#2,#3" ]] || fail "show: STACK_ORDER"$'\n'"$out"
[[ "$(key "$out" STACK_TREES)" == 1 ]] || fail "show: someone else's tree is hidden"
grep -qx 'STACK_CR=2 #3 c main draft failed none waits me stacked-on:b Change c' <<<"$out" \
  || fail "show: STACK_CR for the mis-targeted CR"$'\n'"$out"
grep -qx 'STACK_CR=0 #1 a main ready passed approved now me - Change a' <<<"$out" \
  || fail "show: STACK_CR for the root"$'\n'"$out"
ok "show draws the stack bottom to top, under the branch each CR sits on"

run show --all --repo "$repo"
[[ "$(key "$out" STACK_TREES)" == 2 ]] || fail "show --all: trees"$'\n'"$out"
[[ "$(key "$out" TREE | sed -n 1p)" == "#1 Change a ← mergeable now" ]] || fail "show --all: current tree first"
key "$out" TREE | sed -n 4,5p | grep -qx '#9 Change z ← mergeable now' || fail "show --all: other tree after a blank line"$'\n'"$out"
ok "show --all adds the stacks of others, after the current one"

{
  gh_cr 2 b a false me REVIEW_REQUIRED BLOCKED SUCCESS
  gh_cr 3 c b false me CHANGES_REQUESTED BLOCKED ""
} | jq -s . > "$CR_LIST"
run show --repo "$repo"
expected='#2 Change b ⚠ base a has no open CR
└ #3 Change c · changes requested ← current branch'
[[ "$(key "$out" TREE)" == "$expected" ]] || fail "show: merged base"$'\n'"$out"
grep -q '^STACK_CR=0 #2 b a ready passed required blocked me base-not-open' <<<"$out" || fail "show: base-not-open flag"$'\n'"$out"
ok "a CR whose base has no open CR is flagged at the root"

# --- GitHub: new -----------------------------------------------------------------
echo '{"url":"https://github.com/example/repo/pull/3","number":3,"state":"OPEN"}' > "$VIEW_DIR/c.json"
run new d --repo "$repo"
[[ $rc -eq 0 ]] || fail "new: exit $rc"$'\n'"$out"
[[ "$(key "$out" NEW_BRANCH)" == d && "$(key "$out" BASE_BRANCH)" == c && "$(key "$out" STACKED)" == 1 ]] \
  || fail "new: keys"$'\n'"$out"
[[ "$(key "$out" BASE_CR_REF)" == "#3" && "$(key "$out" BASE_PUSHED)" == 1 ]] || fail "new: base CR"$'\n'"$out"
[[ "$(git -C "$repo" symbolic-ref --short HEAD)" == d ]] || fail "new: d is checked out"
[[ "$(sha d)" == "$(sha c)" ]] || fail "new: d starts at c"
run new d --repo "$repo"
[[ $rc -eq 1 && "$(key "$out" STACK_ERROR)" == *exists* ]] || fail "new: an existing branch"$'\n'"$out"
run new 'bad..name' --repo "$repo"
[[ $rc -eq 1 ]] || fail "new: an invalid name"
git -C "$repo" checkout --quiet main
run new e --repo "$repo"
[[ "$(key "$out" STACKED)" == 0 && -z "$(key "$out" BASE_CR_REF)" ]] || fail "new: from the default branch"$'\n'"$out"
ok "new cuts the next branch on top of the current one"

# --- GitHub: retarget ------------------------------------------------------------
git -C "$repo" checkout --quiet c
{
  gh_cr 1 a main false me APPROVED CLEAN SUCCESS
  gh_cr 2 b a true me REVIEW_REQUIRED DRAFT ""
  gh_cr 3 c main true me "" DRAFT ""
  gh_cr 9 z main false ana APPROVED CLEAN SUCCESS
} | jq -s . > "$CR_LIST"
: > "$EDIT_LOG"
run retarget --onto '#2' --repo "$repo"
[[ $rc -eq 0 && "$(key "$out" RETARGET)" == "done" ]] || fail "retarget: exit $rc"$'\n'"$out"
[[ "$(key "$out" PREVIOUS_TARGET)" == main && "$(key "$out" NEW_TARGET)" == b ]] || fail "retarget: targets"$'\n'"$out"
[[ "$(cat "$EDIT_LOG")" == "pr edit 3 --base b" ]] || fail "retarget: the forge call"$'\n'"$(cat "$EDIT_LOG")"
for form in 2 b origin/b https://github.com/example/repo/pull/2; do
  : > "$EDIT_LOG"
  run retarget --onto "$form" --repo "$repo"
  [[ "$(cat "$EDIT_LOG")" == "pr edit 3 --base b" ]] || fail "retarget: --onto $form"$'\n'"$out"
done
ok "retarget points the CR at a branch named by CR number, branch, or URL"

{
  gh_cr 1 a main false me APPROVED CLEAN SUCCESS
  gh_cr 3 c b true me "" DRAFT ""
} | jq -s . > "$CR_LIST"
: > "$EDIT_LOG"
run retarget --onto b --repo "$repo"
[[ "$(key "$out" RETARGET)" == unchanged && ! -s "$EDIT_LOG" ]] || fail "retarget: already there"$'\n'"$out"
run retarget --onto '#7' --repo "$repo"
[[ $rc -eq 1 && "$(key "$out" STACK_ERROR)" == *"not an open CR"* ]] || fail "retarget: a closed CR"$'\n'"$out"
run retarget --onto nope --repo "$repo"
[[ $rc -eq 1 && "$(key "$out" STACK_ERROR)" == *"no branch"* ]] || fail "retarget: an unknown branch"$'\n'"$out"
git -C "$repo" checkout --quiet a
{
  gh_cr 1 a main false me APPROVED CLEAN SUCCESS
  gh_cr 2 b a false me "" CLEAN ""
  gh_cr 3 c b false me "" CLEAN ""
} | jq -s . > "$CR_LIST"
run retarget --onto c --repo "$repo"
[[ $rc -eq 1 && "$(key "$out" STACK_ERROR)" == *cycle* ]] || fail "retarget: a cycle"$'\n'"$out"
git -C "$repo" checkout --quiet d
run retarget --onto b --repo "$repo"
[[ $rc -eq 0 && "$(key "$out" RETARGET)" == no-cr ]] || fail "retarget: no CR"$'\n'"$out"
ok "retarget refuses a closed CR, an unknown branch, and a cycle, and reports no CR"

git -C "$repo" checkout --quiet z
{
  gh_cr 1 a main false me APPROVED CLEAN SUCCESS
  gh_cr 9 z main false ana APPROVED CLEAN SUCCESS
} | jq -s . > "$CR_LIST"
: > "$EDIT_LOG"
run retarget --onto a --repo "$repo"
[[ $rc -eq 66 && "$(key "$out" CONFIRM_OTHERS)" == "#9:ana" && ! -s "$EDIT_LOG" ]] || fail "retarget: someone else's CR"$'\n'"$out"
run retarget --onto a --allow-others --repo "$repo"
[[ $rc -eq 0 && "$(cat "$EDIT_LOG")" == "pr edit 9 --base a" ]] || fail "retarget: --allow-others"$'\n'"$out"
EDIT_FAIL=1 run retarget --onto a --allow-others --repo "$repo"
[[ $rc -eq 1 && "$(key "$out" STACK_AUTH)" == 1 ]] || fail "retarget: an auth failure"$'\n'"$out"
ok "retarget asks before moving someone else's CR, and marks an auth failure"

# --- GitLab -----------------------------------------------------------------------
repo=$(make_repo gitlab.com)
{
  gl_cr 1 a main false me need_rebase
  gl_cr 2 b a false me not_approved
  gl_cr 3 c b true me draft_status
} | jq -s . > "$CR_LIST"
echo '{"head_pipeline":{"status":"success"}}' > "$MR_DIR/1.json"
echo '{"approved":true,"approvals_left":0,"approved_by":[{"user":{"username":"ana"}}]}' > "$MR_DIR/1-approvals.json"
echo '{"head_pipeline":{"status":"failed"}}' > "$MR_DIR/2.json"
echo '{"approved":false,"approvals_left":1,"approved_by":[]}' > "$MR_DIR/2-approvals.json"
echo '{"head_pipeline":null}' > "$MR_DIR/3.json"
echo '{"approved":false,"approvals_left":0,"approved_by":[]}' > "$MR_DIR/3-approvals.json"
run show --repo "$repo"
[[ $rc -eq 0 ]] || fail "gitlab show: exit $rc"$'\n'"$out"
expected='!1 Change a · behind its base
└ !2 Change b · checks failing
  └ !3 Change c (draft) ← current branch'
[[ "$(key "$out" TREE)" == "$expected" ]] || fail "gitlab show: tree"$'\n'"$out"
grep -qx 'STACK_CR=0 !1 a main ready passed approved behind me - Change a' <<<"$out" || fail "gitlab show: !1"$'\n'"$out"
grep -qx 'STACK_CR=1 !2 b a ready failed required waits me - Change b' <<<"$out" || fail "gitlab show: !2"$'\n'"$out"
[[ "$(key "$out" STACK_ORDER)" == '!1,!2,!3' ]] || fail "gitlab show: order"
ok "GitLab: each MR's pipeline and approvals come from its own record"

: > "$EDIT_LOG"
run retarget --onto '!1' --repo "$repo"
[[ "$(cat "$EDIT_LOG")" == "mr update 3 --target-branch a" ]] || fail "gitlab retarget"$'\n'"$out"$'\n'"$(cat "$EDIT_LOG")"
ok "GitLab: retarget sets the MR's target branch"

run show --bogus
[[ $rc -eq 64 ]] || fail "usage: exit $rc"
run retarget --repo "$repo"
[[ $rc -eq 64 ]] || fail "usage: retarget without --onto"
ok "usage errors exit 64"
