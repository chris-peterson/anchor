#!/usr/bin/env bash
# Functional test for scripts/merge-gates.sh.
#
# Drives the real script, and the real pipeline-status.sh it calls, against stub
# `gh` / `glab` that serve a CR's JSON from fixture files, so what is asserted is
# the gate each forge field maps to and where the read stops.
#
# The cases worth pinning are the ones a skill reading raw fields got wrong or
# had to re-derive: a gate that doesn't apply (no approval rules, no pipeline)
# passing rather than blocking, the first blocking gate ending the read, and the
# merge method moving off the merge-commit default only where a setting says so.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gates="$here/../scripts/merge-gates.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$out"; }
expect() { [[ "$(val "$1")" == "$2" ]] || fail "$3: $1 was '$(val "$1")', expected '$2'"$'\n'"$out"; }

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-merge-gates-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
fx="$work/fx"
mkdir -p "$bin" "$fx"
export FX="$fx"

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "pr view")   cat "$FX/gh-pr.json" ;;
  "repo view") cat "$FX/gh-repo.json" ;;
  "api graphql") cat "$FX/gh-threads.json" ;;
  "run view")  jq -c '{jobs: .}' "$FX/gh-jobs.json" ;;
  api\ *)      jq -c '{total_count: length, workflow_runs: .}' "$FX/gh-runs.json" ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
EOF

cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "mr view" ]]; then cat "$FX/gl-mr.json"; exit 0; fi
[[ "${1:-}" == api ]] || { echo "stub glab: unhandled: $*" >&2; exit 1; }
shift
[[ "${1:-}" == --paginate ]] && shift
case "$1" in
  */commits*)     cat "$FX/gl-commits.json" ;;
  */approvals)    cat "$FX/gl-approvals.json" ;;
  */discussions*) cat "$FX/gl-discussions.json" ;;
  */jobs*)        cat "$FX/gl-jobs.json" ;;
  *pipelines*)    cat "$FX/gl-pipes.json" ;;
  projects/:fullpath) cat "$FX/gl-project.json" ;;
  *) echo "stub glab: unhandled api path: $1" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"
export MERGE_GATES_MERGEABLE_DELAY=0

new_repo() {
  local repo="$work/$1"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m seed
  git -C "$repo" checkout --quiet -b feature
  printf 'change\n' >> "$repo/README.md"
  git -C "$repo" commit --quiet -am change
  git -C "$repo" remote add origin "$2"
}

run() {
  out=""; status=0
  out="$(bash "$gates" --repo "$repo" 2>&1)" || status=$?
}

# --- GitHub -----------------------------------------------------------------

repo="$work/gh"
new_repo gh "https://github.com/acme/widget.git"
head=$(git -C "$repo" rev-parse HEAD)

gh_pr() {
  jq -n --arg sha "$head" '{
    number: 128, url: "https://github.com/acme/widget/pull/128", title: "Widen the widget",
    state: "OPEN", isDraft: false, headRefOid: $sha, headRefName: "feature", baseRefName: "main",
    mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
    commits: [{}, {}, {}] }' | jq "${1:-.}" > "$fx/gh-pr.json"
}
gh_runs() {
  jq -n --arg sha "$head" --arg c "${1:-success}" '[{ id: 7, name: "Test", path: ".github/workflows/test.yml",
    head_branch: "feature", head_sha: $sha, status: (if $c == "running" then "in_progress" else "completed" end),
    conclusion: (if $c == "running" then null else $c end), created_at: "2026-09-29T12:00:00Z",
    html_url: "https://github.com/acme/widget/actions/runs/7" }]' > "$fx/gh-runs.json"
}
printf '[{"name":"unit","status":"completed","conclusion":"success","url":"u1"},
         {"name":"lint","status":"completed","conclusion":"success","url":"u2"}]' > "$fx/gh-jobs.json"
printf '{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true}' > "$fx/gh-repo.json"
gh_threads() {
  jq -n --argjson nodes "${1:-[]}" '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes}}}}}' > "$fx/gh-threads.json"
}

gh_pr; gh_runs; gh_threads
run
[[ "$status" == 0 ]] || fail "all green exited $status: $out"
expect CR_REF '#128' "github ref"
expect LOCAL_STATE ok "matching head"
expect GATE_DRAFT clear "not a draft"
expect GATE_MERGEABLE ok "clean"
expect GATE_PIPELINE success "green run"
expect GATE_PIPELINE_DETAIL "2/2 jobs on ${head:0:7}" "job count"
expect GATE_APPROVALS met "approved"
expect GATE_THREADS resolved "no threads"
expect GATE_BLOCKING "" "nothing blocks"
expect MERGE_METHOD merge "merge-commit default"
expect MERGE_METHOD_LABEL "merge commit (preserves 3 commits)" "label counts commits"
expect MERGE_METHOD_SETTING "" "no setting moved it"
ok "github: every gate green resolves the merge-commit default"

gh_pr '.reviewDecision = null'
run
expect GATE_APPROVALS none "no review rules"
expect GATE_BLOCKING "" "no rules is not a block"
ok "github: no approval rules passes the gate"

gh_pr; printf '[]' > "$fx/gh-runs.json"
run
expect GATE_PIPELINE none "no runs"
expect GATE_BLOCKING "" "no pipeline is not a block"
ok "github: a commit with no pipeline passes the gate"

gh_pr '.isDraft = true'
run
expect GATE_DRAFT draft "draft"
expect GATE_BLOCKING draft "draft blocks"
[[ -z "$(val GATE_MERGEABLE)" ]] || fail "read went past the draft gate"$'\n'"$out"
ok "github: a draft stops the read at the draft gate"

gh_pr '.mergeStateStatus = "BEHIND"'
run
expect GATE_MERGEABLE behind "behind base"
expect GATE_BLOCKING mergeable "behind blocks"
ok "github: a branch behind its base blocks on mergeable"

gh_pr '.mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
run
expect GATE_MERGEABLE unknown "still computing"
ok "github: mergeability the forge hasn't computed reads unknown after the retries"

gh_pr; gh_runs running
run
expect GATE_PIPELINE running "in progress"
expect GATE_BLOCKING pipeline "running blocks"
ok "github: a running pipeline blocks on the pipeline gate"

gh_runs failure
run
expect GATE_PIPELINE failed "failed run"
ok "github: a failed pipeline blocks"

gh_runs; gh_pr '.reviewDecision = "CHANGES_REQUESTED"'
run
expect GATE_APPROVALS changes-requested "changes requested"
expect GATE_BLOCKING approvals "changes requested blocks"
ok "github: requested changes block on approvals"

gh_pr; gh_threads '[
  {"isResolved":false,"path":"a.sh","line":3,"comments":{"nodes":[{"author":{"login":"ana","__typename":"User"},"body":"why?"}]}},
  {"isResolved":false,"path":"b.sh","line":9,"comments":{"nodes":[{"author":{"login":"lint-bot","__typename":"Bot"},"body":"nit"}]}},
  {"isResolved":true,"path":"c.sh","line":1,"comments":{"nodes":[{"author":{"login":"bo","__typename":"User"},"body":"ok"}]}}]'
run
expect GATE_THREADS open "one human thread open"
expect GATE_THREADS_DETAIL "1 unresolved" "bot and resolved threads excluded"
expect GATE_BLOCKING threads "threads block"
expect MERGE_METHOD merge "method still read past open threads"
[[ "$(val THREADS | jq -r '.[0].author')" == ana ]] || fail "THREADS carries the thread"$'\n'"$out"
ok "github: open human threads block but the method is still read"

gh_threads
printf '{"mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":true}' > "$fx/gh-repo.json"
run
expect MERGE_METHOD rebase "rebase ahead of squash"
expect MERGE_METHOD_SETTING "the repo disallows merge commits" "setting named"
printf '{"mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":false}' > "$fx/gh-repo.json"
run
expect MERGE_METHOD squash "squash only"
expect MERGE_SQUASH 1 "squash flag"
printf '{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true}' > "$fx/gh-repo.json"
ok "github: disallowed merge commits fall to rebase, then squash"

printf 'dirty\n' > "$repo/untracked.txt"
run
expect LOCAL_STATE dirty "untracked file"
expect GATE_BLOCKING local "dirty blocks"
rm "$repo/untracked.txt"
gh_pr '.headRefOid = "0000000000000000000000000000000000000000"'
run
expect LOCAL_STATE head-mismatch "different head"
expect GATE_BLOCKING local "mismatch blocks"
ok "github: a dirty tree or a head the CR doesn't carry stops before the gates"

gh_pr '.state = "MERGED"'
run
expect CR_STATE merged "already merged"
expect GATE_BLOCKING state "merged stops"
ok "github: an already-merged CR stops at state"

# --- GitLab -----------------------------------------------------------------

repo="$work/gl"
new_repo gl "git@gitlab.example.com:group/sub/widget.git"
head=$(git -C "$repo" rev-parse HEAD)

gl_mr() {
  jq -n --arg sha "$head" '{
    iid: 42, web_url: "https://gitlab.example.com/group/sub/widget/-/merge_requests/42",
    title: "Widen the widget", state: "opened", draft: false, sha: $sha,
    source_branch: "feature", target_branch: "main",
    detailed_merge_status: "mergeable", squash: false }' | jq "${1:-.}" > "$fx/gl-mr.json"
}
printf '[{},{}]' > "$fx/gl-commits.json"
jq -n --arg sha "$head" '[{id: 9, sha: $sha, ref: "feature", status: "success", web_url: "https://gitlab.example.com/p/9"}]' > "$fx/gl-pipes.json"
printf '[{"name":"test","stage":"test","status":"success","web_url":"j1"}]' > "$fx/gl-jobs.json"
printf '{"approvals_required":1,"approvals_left":0,"approved_by":[{"user":{"username":"ana"}}]}' > "$fx/gl-approvals.json"
printf '[]' > "$fx/gl-discussions.json"
printf '{"merge_method":"merge","squash_option":"default_off"}' > "$fx/gl-project.json"

gl_mr
run
[[ "$status" == 0 ]] || fail "gitlab all green exited $status: $out"
expect CR_REF '!42' "gitlab ref"
expect CR_STATE open "opened normalizes to open"
expect GATE_PIPELINE success "green pipeline"
expect GATE_APPROVALS met "approved"
expect GATE_APPROVALS_DETAIL "1 required, 0 left; approved by @ana" "approval detail"
expect GATE_BLOCKING "" "nothing blocks"
expect MERGE_METHOD_LABEL "merge commit (preserves 2 commits)" "label"
ok "gitlab: every gate green resolves the merge-commit default"

printf '{"approvals_required":0,"approvals_left":0,"approved_by":[]}' > "$fx/gl-approvals.json"
run
expect GATE_APPROVALS none "no rules"
printf '{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"username":"ana"}}]}' > "$fx/gl-approvals.json"
run
expect GATE_APPROVALS missing "one left"
expect GATE_BLOCKING approvals "missing blocks"
printf '{"approvals_required":1,"approvals_left":0,"approved_by":[{"user":{"username":"ana"}}]}' > "$fx/gl-approvals.json"
ok "gitlab: no rules passes, approvals left block"

gl_mr '.detailed_merge_status = "need_rebase"'
run
expect GATE_MERGEABLE behind "need_rebase"
gl_mr '.detailed_merge_status = "conflict"'
run
expect GATE_MERGEABLE conflicts "conflict"
gl_mr '.detailed_merge_status = "not_approved"'
run
expect GATE_MERGEABLE ok "a gate-not-met state is left to its own gate"
ok "gitlab: detailed_merge_status maps to the mergeable gate"

gl_mr
printf '[{"notes":[{"system":false,"resolvable":true,"resolved":false,"author":{"username":"bo"},"body":"rename?","position":{"new_path":"x.sh","new_line":4}}]},
         {"notes":[{"system":true,"resolvable":false,"resolved":false,"author":{"username":"gitlab"},"body":"added 1 commit"}]}]' > "$fx/gl-discussions.json"
run
expect GATE_THREADS open "one open"
expect GATE_THREADS_DETAIL "1 unresolved" "system note excluded"
printf '[]' > "$fx/gl-discussions.json"
ok "gitlab: open discussions block, system notes don't count"

printf '{"merge_method":"ff","squash_option":"default_off"}' > "$fx/gl-project.json"
run
expect MERGE_METHOD ff "fast-forward project"
expect MERGE_METHOD_LABEL "fast-forward, no merge commit" "ff label"
expect MERGE_METHOD_SETTING "the project's merge method is fast-forward" "ff setting"
printf '{"merge_method":"merge","squash_option":"always"}' > "$fx/gl-project.json"
run
expect MERGE_SQUASH 1 "squash always"
expect MERGE_METHOD_SETTING "the project requires squash" "squash setting"
printf '{"merge_method":"merge","squash_option":"default_on"}' > "$fx/gl-project.json"
gl_mr '.squash = true'
run
expect MERGE_SQUASH 1 "MR checkbox"
expect MERGE_METHOD_SETTING "the MR is set to squash" "MR setting"
gl_mr '.squash = false'
run
expect MERGE_SQUASH 0 "MR checkbox off"
ok "gitlab: merge_method, squash_option, and the MR's squash flag move the method"

echo "PASS"
