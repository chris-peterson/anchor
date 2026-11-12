#!/usr/bin/env bash
# Functional test for scripts/rebase.sh.
#
# Drives the real script against a local bare remote and stub `gh` / `glab` that
# serve the branch's CR and the open-CR listing. The remote path embeds
# `github.com` / `gitlab.com` because forge detection matches on the origin URL.
#
# The push is what carries the weight: a branch is force-pushed only where
# origin's copy matched it before the rebase, so a state read wrong either
# publishes commits nobody reviewed or overwrites a push someone else made. The
# cascade cases check that each branch replays only its own commits.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rebase_sh="$here/../scripts/rebase.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  echo "PASS"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-rebase-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# Both stubs serve $CR_JSON for the branch's CR (an empty file == none open) and
# $CR_LIST for the open-CR listing; CR_LIST_FAIL=1 fails the listing.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "pr view") [[ -s "$CR_JSON" ]] || exit 1; cat "$CR_JSON" ;;
  "pr list") [[ "${CR_LIST_FAIL:-0}" == 1 ]] && { echo "stub gh: HTTP 401" >&2; exit 1; }
             if [[ -s "$CR_LIST" ]]; then cat "$CR_LIST"; else echo '[]'; fi ;;
  "api user") echo "$VIEWER_LOGIN" ;;
  *) echo "stub gh: unhandled command: $*" >&2; exit 1 ;;
esac
EOF
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "mr view") [[ -s "$CR_JSON" ]] || exit 1; cat "$CR_JSON" ;;
  "mr list") [[ "${CR_LIST_FAIL:-0}" == 1 ]] && { echo "stub glab: 401" >&2; exit 1; }
             if [[ -s "$CR_LIST" ]]; then cat "$CR_LIST"; else echo '[]'; fi ;;
  "api user") printf '{"username":"%s"}\n' "$VIEWER_LOGIN" ;;
  *) echo "stub glab: unhandled command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"

export CR_JSON="$work/cr.json"
export CR_LIST="$work/cr-list.json"
export CR_LIST_FAIL=0
export VIEWER_LOGIN=me

key() { sed -n "s/^$2=//p" <<<"$1"; }
reset_forge() { : > "$CR_JSON"; : > "$CR_LIST"; CR_LIST_FAIL=0; }

identity() {
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
  git -C "$1" config commit.gpgsign false
}

# commit_file <repo> <file> [content]
commit_file() {
  printf '%s\n' "${3:-$2}" > "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit --quiet -m "Change $2"
}

# make_repo <host> <name>: a pushed feature branch `feat` one commit ahead of
# main, with origin's main then advanced by a commit from another clone, so the
# local main is behind too. Echoes the repo path; the other clone is <repo>-peer.
make_repo() {
  local host=$1 name=$2 remote repo peer
  remote="$work/remotes/$name/$host/example/repo.git"
  repo="$work/repos/$name"
  peer="$work/repos/$name-peer"
  mkdir -p "$(dirname "$remote")" "$(dirname "$repo")"
  git init --quiet --bare -b main "$remote"
  git init --quiet -b main "$repo"
  identity "$repo"
  commit_file "$repo" seed.txt
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" remote set-head origin main
  git -C "$repo" checkout --quiet -b feat
  commit_file "$repo" a.txt
  git -C "$repo" push --quiet -u origin feat
  git clone --quiet -b main "$remote" "$peer"
  identity "$peer"
  commit_file "$peer" main2.txt
  git -C "$peer" push --quiet origin main
  echo "$repo"
}

# peer_push <repo> <branch> <file> [content]: a commit pushed by someone else.
peer_push() {
  local peer="$1-peer"
  git -C "$peer" fetch --quiet origin
  git -C "$peer" checkout --quiet -B "$2" "origin/$2"
  commit_file "$peer" "$3" "${4:-$3}"
  git -C "$peer" push --quiet origin "$2"
}

run() { local dir=$1; shift; (cd "$dir" && bash "$rebase_sh" "$@"); }
# run_status <dir> <args...>: sets $out and $status without tripping set -e.
run_status() { set +e; out="$(run "$@")"; status=$?; set -e; }
origin_sha() { git -C "$1" rev-parse "refs/remotes/origin/$2"; }

# --- --check ------------------------------------------------------------------------

reset_forge
repo="$(make_repo github.com gh-check)"
out="$(run "$repo" --check)"
[[ "$(key "$out" FORGE)" == github && "$(key "$out" BRANCH)" == feat ]] || fail "forge/branch: $out"
[[ "$(key "$out" BASE_BRANCH)" == main && "$(key "$out" BASE_SOURCE)" == default && -z "$(key "$out" STACK_CHAIN)" ]] \
  || fail "base: $out"
[[ "$(key "$out" BEHIND)" == 1 && "$(key "$out" AHEAD)" == 1 ]] || fail "ahead/behind: $out"
[[ "$(key "$out" PUSH_STATE)" == match && "$(key "$out" PUSHED_SHA)" == "$(git -C "$repo" rev-parse HEAD)" ]] \
  || fail "a branch pushed as it stands reads as match: $out"
[[ "$(git -C "$repo" rev-parse main)" != "$(origin_sha "$repo" main)" ]] || fail "--check must not move main"
ok "--check reads the base and push state, and moves nothing"

commit_file "$repo" b.txt
[[ "$(key "$(run "$repo" --check)" PUSH_STATE)" == ahead ]] || fail "an unpushed commit reads as ahead"
git -C "$repo" reset --quiet --hard HEAD~2
[[ "$(key "$(run "$repo" --check)" PUSH_STATE)" == behind ]] || fail "a checkout missing a pushed commit reads as behind"
commit_file "$repo" c.txt
[[ "$(key "$(run "$repo" --check)" PUSH_STATE)" == diverged ]] || fail "both sides with commits read as diverged"
git -C "$repo" checkout --quiet -b fresh main
commit_file "$repo" fresh.txt
[[ "$(key "$(run "$repo" --check)" PUSH_STATE)" == unpushed ]] || fail "a branch origin lacks reads as unpushed"
ok "--check reads ahead, behind, diverged, and unpushed"

# --- A single branch ----------------------------------------------------------------

reset_forge
repo="$(make_repo github.com gh-run)"
run_status "$repo"
[[ "$status" -eq 0 && "$(key "$out" REBASE_STATUS)" == "done" && "$(key "$out" RESULT)" == feat:rebased:pushed ]] \
  || fail "a pushed branch behind main should rebase and push (status $status): $out"
[[ "$(key "$out" DEFAULT_FF)" == fast-forwarded && "$(git -C "$repo" rev-parse main)" == "$(origin_sha "$repo" main)" ]] \
  || fail "the local main should be fast-forwarded to origin's: $out"
git -C "$repo" fetch --quiet origin
[[ "$(origin_sha "$repo" feat)" == "$(git -C "$repo" rev-parse HEAD)" && "$(key "$out" NEW_HEAD_SHA)" == "$(git -C "$repo" rev-parse HEAD)" ]] \
  || fail "origin's feat should be the rebased head"
git -C "$repo" merge-base --is-ancestor "origin/main" HEAD || fail "feat should sit on origin/main"
ok "a pushed branch is rebased, force-pushed, and main fast-forwarded"

run_status "$repo"
[[ "$status" -eq 0 && "$(key "$out" REBASE_STATUS)" == up-to-date && "$(key "$out" RESULT)" == feat:unchanged:- && "$(key "$out" DEFAULT_FF)" == up-to-date ]] \
  || fail "a branch already on its base is a clean no-op (status $status): $out"
ok "a branch already up to date is a no-op that succeeds"

reset_forge
repo="$(make_repo github.com gh-ahead)"
commit_file "$repo" b.txt
before="$(origin_sha "$repo" feat)"
run_status "$repo"
[[ "$status" -eq 0 && "$(key "$out" RESULT)" == feat:rebased:not-pushed-ahead ]] || fail "unpushed commits: $out"
git -C "$repo" fetch --quiet origin
[[ "$(origin_sha "$repo" feat)" == "$before" ]] || fail "a branch with unpushed commits must not be pushed"
ok "a branch with unpushed commits is rebased and not pushed"

reset_forge
repo="$(make_repo github.com gh-peer)"
peer_push "$repo" feat p.txt
head_before="$(git -C "$repo" rev-parse HEAD)"
run_status "$repo"
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *"holds commits this checkout lacks"* ]] \
  || fail "a push someone else made should refuse the rebase (status $status): $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$head_before" ]] || fail "a refused run must not rewrite the branch"
ok "a branch origin holds newer commits of is refused before anything moves"

reset_forge
repo="$(make_repo github.com gh-dirty)"
printf 'dirty\n' >> "$repo/a.txt"
run_status "$repo"
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *uncommitted* ]] || fail "uncommitted changes: $out"
ok "uncommitted changes are refused"

reset_forge
repo="$(make_repo github.com gh-default)"
git -C "$repo" checkout --quiet main
run_status "$repo"
[[ "$status" -eq 0 && "$(key "$out" REBASE_STATUS)" == default-branch && "$(key "$out" DEFAULT_FF)" == fast-forwarded ]] \
  || fail "on main, the run fast-forwards it and succeeds (status $status): $out"
ok "on the default branch, a run fast-forwards it and succeeds"

# --- Conflicts ----------------------------------------------------------------------

reset_forge
repo="$(make_repo github.com gh-conflict)"
peer_push "$repo" main a.txt "main side"
head_before="$(git -C "$repo" rev-parse HEAD)"
run_status "$repo"
[[ "$status" -eq 75 && "$(key "$out" REBASE_STATUS)" == conflict && "$(key "$out" CONFLICT_FILES)" == a.txt && "$(key "$out" CONFLICT_BRANCH)" == feat ]] \
  || fail "a conflict should stop with exit 75 naming the file (status $status): $out"
[[ "$(key "$(run "$repo" --check)" PLAN_PENDING)" == 1 ]] || fail "--check should report the unfinished run"
run_status "$repo" --continue
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *"markers remain"*a.txt* ]] || fail "unresolved markers: $out"
run_status "$repo" --abort
[[ "$status" -eq 0 && "$(key "$out" REBASE_STATUS)" == aborted && "$(git -C "$repo" rev-parse HEAD)" == "$head_before" ]] \
  || fail "--abort should put the branch back (status $status): $out"
ok "a conflict stops at exit 75, refuses markers, and --abort puts the branch back"

run_status "$repo"
[[ "$status" -eq 75 ]] || fail "the conflict should recur: $out"
printf 'both sides\n' > "$repo/a.txt"
run_status "$repo" --continue
[[ "$status" -eq 0 && "$(key "$out" RESULT)" == feat:rebased:pushed ]] || fail "--continue after resolving (status $status): $out"
git -C "$repo" fetch --quiet origin
[[ "$(git -C "$repo" show origin/feat:a.txt)" == "both sides" ]] || fail "the resolution should be what was pushed"
ok "--continue stages the resolution, finishes, and pushes"

# --- Base resolution ----------------------------------------------------------------

reset_forge
repo="$(make_repo github.com gh-cr)"
git -C "$repo" push --quiet origin main:release
printf '{"url":"https://github.com/example/repo/pull/7","number":7,"isDraft":false,"baseRefName":"release","state":"OPEN"}\n' > "$CR_JSON"
out="$(run "$repo" --check)"
[[ "$(key "$out" BASE_BRANCH)" == release && "$(key "$out" BASE_SOURCE)" == cr && "$(key "$out" CR_DRAFT)" == false ]] \
  || fail "the CR's target is the base: $out"
run_status "$repo" --check --onto main
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *release* ]] || fail "--onto against the CR's target: $out"
ok "an open PR's target is the base, and a disagreeing --onto is refused"

reset_forge
repo="$(make_repo github.com gh-ready)"
printf '{"url":"https://github.com/example/repo/pull/8","number":8,"isDraft":false,"baseRefName":"main","state":"OPEN","author":{"login":"me"}}\n' > "$CR_JSON"
head_before="$(git -C "$repo" rev-parse HEAD)"
run_status "$repo"
[[ "$status" -eq 66 && "$(key "$out" CONFIRM_READY)" == feat:8 && "$(key "$out" REBASE_STATUS)" == needs-confirmation ]] \
  || fail "a ready CR's force-push should need a yes (status $status): $out"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$head_before" && "$(git -C "$repo" rev-parse main)" != "$(origin_sha "$repo" main)" ]] \
  || fail "nothing should move before the yes"
run_status "$repo" --allow-ready
[[ "$status" -eq 0 && "$(key "$out" RESULT)" == feat:rebased:pushed && -z "$(key "$out" NOTIFY)" ]] \
  || fail "--allow-ready should rebase and push (status $status): $out"
ok "a ready CR exits 66 before anything moves, and --allow-ready pushes it"

reset_forge
run_status "$repo" --onto nope
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *"no branch 'nope'"* ]] || fail "--onto origin lacks: $out"
ok "an --onto origin doesn't have is refused"

# --- Stacks -------------------------------------------------------------------------

# stack_repo <name>: feat (PR #5 into main) with feat2 (no CR) cut from it, both
# pushed, and origin's main advanced.
stack_repo() {
  local repo
  repo="$(make_repo github.com "$1")"
  git -C "$repo" checkout --quiet -b feat2
  commit_file "$repo" s.txt
  git -C "$repo" push --quiet -u origin feat2
  printf '[{"headRefName":"feat","headRefOid":"%s","number":5,"url":"https://github.com/example/repo/pull/5","baseRefName":"main","isDraft":true,"author":{"login":"me"}}]\n' \
    "$(git -C "$repo" rev-parse feat)" > "$CR_LIST"
  echo "$repo"
}

reset_forge
repo="$(stack_repo gh-stack)"
out="$(run "$repo" --check)"
[[ "$(key "$out" BASE_BRANCH)" == feat && "$(key "$out" BASE_SOURCE)" == stacked && "$(key "$out" STACK_CHAIN)" == feat && "$(key "$out" STACK_CR_IID)" == 5 ]] \
  || fail "a branch stacked on an open PR: $out"
ok "--check names the stack under a stacked branch"

run_status "$repo" --cascade
[[ "$status" -eq 0 ]] || fail "cascade (status $status): $out"
[[ "$(key "$out" RESULT | paste -sd' ' -)" == "feat:rebased:pushed feat2:rebased:pushed" ]] || fail "cascade results: $out"
git -C "$repo" fetch --quiet origin
git -C "$repo" merge-base --is-ancestor origin/main origin/feat || fail "feat should sit on origin/main"
[[ "$(git -C "$repo" rev-parse origin/feat2~1)" == "$(git -C "$repo" rev-parse origin/feat)" ]] \
  || fail "feat2 should be its one commit on the rebased feat"
[[ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" == feat2 ]] || fail "the run should end on the branch it started on"
ok "--cascade rebases the lowest branch onto main, then the one above onto it"

reset_forge
repo="$(stack_repo gh-stack-others)"
sed -i.bak 's/"login":"me"/"login":"alice"/' "$CR_LIST"
out="$(run "$repo" --check)"
[[ "$(key "$out" STACK_BRANCH)" == feat:5:true:alice && "$(key "$out" VIEWER)" == me ]] \
  || fail "--check should name each branch under this one with its CR's owner: $out"
run_status "$repo" --cascade
[[ "$status" -eq 66 && "$(key "$out" CONFIRM_OTHERS)" == feat:5:alice ]] \
  || fail "a cascade over someone else's branch should need a yes (status $status): $out"
run_status "$repo" --cascade --allow-others
[[ "$status" -eq 0 && "$(key "$out" NOTIFY)" == feat:5:alice ]] \
  || fail "a push under someone else's CR should name its owner (status $status): $out"
ok "a cascade over someone else's branch exits 66, and --allow-others names the owner to tell"

reset_forge
repo="$(stack_repo gh-stack-fix)"
peer_push "$repo" feat fix.txt
run_status "$repo" --cascade
[[ "$status" -eq 0 ]] || fail "cascade over a predecessor with a new commit (status $status): $out"
git -C "$repo" fetch --quiet origin
[[ "$(git -C "$repo" rev-parse origin/feat2~1)" == "$(git -C "$repo" rev-parse origin/feat)" ]] \
  || fail "feat2 should land on feat including the fix pushed after it was cut"
git -C "$repo" cat-file -e origin/feat2:fix.txt || fail "the fix should be under feat2"
ok "a predecessor's newer commits on origin are taken before the cascade"

reset_forge
repo="$(stack_repo gh-stack-single)"
run_status "$repo"
[[ "$status" -eq 0 && "$(key "$out" RESULT)" == feat2:unchanged:- && "$(key "$out" REBASE_STATUS)" == up-to-date ]] \
  || fail "without --cascade, a branch on an unchanged predecessor is up to date: $out"
ok "without --cascade, only the branch itself is rebased, onto its predecessor"

reset_forge
repo="$(stack_repo gh-stack-abort)"
peer_push "$repo" main s.txt "main side"
feat_before="$(git -C "$repo" rev-parse feat)"
feat2_before="$(git -C "$repo" rev-parse feat2)"
run_status "$repo" --cascade
[[ "$status" -eq 75 && "$(key "$out" CONFLICT_BRANCH)" == feat2 ]] || fail "a conflict in the upper branch (status $status): $out"
[[ "$(git -C "$repo" rev-parse feat)" != "$feat_before" ]] || fail "the lower branch should already be rebased"
run_status "$repo" --abort
[[ "$status" -eq 0 && "$(git -C "$repo" rev-parse feat)" == "$feat_before" && "$(git -C "$repo" rev-parse HEAD)" == "$feat2_before" ]] \
  || fail "--abort should put every branch the cascade moved back (status $status): $out"
git -C "$repo" fetch --quiet origin
[[ "$(origin_sha "$repo" feat)" == "$feat_before" ]] || fail "nothing is pushed before the whole cascade lands"
ok "--abort mid-cascade puts the lower branches back, with nothing pushed"

reset_forge
repo="$(make_repo github.com gh-nostack)"
run_status "$repo" --cascade
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *"nothing to cascade"* ]] || fail "--cascade unstacked: $out"
ok "--cascade on a branch that isn't stacked is refused"

reset_forge
repo="$(stack_repo gh-stack-fail)"
CR_LIST_FAIL=1
out="$(run "$repo" --check)"
[[ "$(key "$out" STACK_LOOKUP_ERROR)" == *401* ]] || fail "a failed listing: $out"
run_status "$repo"
[[ "$status" -eq 1 && "$(key "$out" REBASE_ERROR)" == *401* ]] || fail "a run with a failed listing should refuse: $out"
ok "a failed CR listing is reported, and a run refuses rather than guess the base"

# --- GitLab -------------------------------------------------------------------------

reset_forge
repo="$(make_repo gitlab.com gl-cr)"
printf '{"web_url":"https://gitlab.com/example/repo/-/merge_requests/9","iid":9,"draft":true,"target_branch":"main","state":"opened"}\n' > "$CR_JSON"
out="$(run "$repo" --check)"
[[ "$(key "$out" FORGE)" == gitlab && "$(key "$out" CR_IID)" == 9 && "$(key "$out" CR_DRAFT)" == true && "$(key "$out" BASE_SOURCE)" == cr ]] \
  || fail "an open MR's keys: $out"
run_status "$repo"
[[ "$status" -eq 0 && "$(key "$out" RESULT)" == feat:rebased:pushed ]] || fail "a GitLab run: $out"
ok "an open MR is read and its branch rebased on GitLab"

echo "PASS"
