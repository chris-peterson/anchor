#!/usr/bin/env bash
# Functional test for scripts/pipeline-status.sh — the pipeline verdict the
# `pipeline` skill reports instead of hand-rolling a poll loop.
#
# Drives the real script against stub `gh` / `glab` binaries that filter their
# fixtures the way the real CLIs filter server-side: `gh run list --branch B`
# matches on head_branch, `glab api pipelines?ref=R` matches on ref. That
# faithfulness is what makes the load-bearing case here a real regression test —
# a run triggered by a release or a tag carries the *tag* as its head_branch, so
# any ref-scoped lookup misses it even though the run is for this exact commit.
#
# Requires jq.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status="$here/../scripts/pipeline-status.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-pipeline-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub gh: serves $GH_RUNS (workflow runs, API shape) and $GH_JOBS (a run's
# jobs). `run list --branch B` filters by head_branch and `api …head_sha=S` by
# head_sha, so each lookup shape sees exactly what the real API would return.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${GH_ARGS_FILE:-}" ] && printf '%s\n' "$*" >> "$GH_ARGS_FILE"
sub="${1:-}"; shift || true
case "$sub" in
  api)
    path="${1:-}"
    case "$path" in
      *actions/runs*)
        sha="${path##*head_sha=}"; sha="${sha%%&*}"
        jq -c --arg sha "$sha" \
          '[ .[] | select(.head_sha == $sha) ]
           | {total_count: length, workflow_runs: .}' "$GH_RUNS"
        ;;
      *) echo "stub gh: unhandled api path: $path" >&2; exit 1 ;;
    esac
    ;;
  run)
    case "${1:-}" in
      list)
        branch=""
        while [ $# -gt 0 ]; do
          case "$1" in --branch) branch="${2:-}"; shift 2 ;; *) shift ;; esac
        done
        jq -c --arg b "$branch" \
          '[ .[] | select(.head_branch == $b)
                 | {databaseId: .id, status, conclusion,
                    headSha: .head_sha, url: .html_url} ]' "$GH_RUNS"
        ;;
      # `run view <id>` answers per run, so a fixture named for the run id wins
      # over the shared one — that's what lets a breakdown assertion tell one
      # run's jobs from another's.
      view)
        f="${GH_JOBS_DIR:-}/jobs-${2:-}.json"
        [ -f "$f" ] || f="$GH_JOBS"
        jq -c '{jobs: .}' "$f"
        ;;
      *) echo "stub gh: unhandled run subcommand: ${1:-}" >&2; exit 1 ;;
    esac
    ;;
  *) echo "stub gh: unhandled command: $sub" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh"

# --- stub glab: serves $GLAB_PIPES, honoring whichever of ref= / sha= the
# caller put in the query — the same narrowing the pipelines API applies.
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${GLAB_ARGS_FILE:-}" ] && printf '%s\n' "$*" >> "$GLAB_ARGS_FILE"
path="${2:-}"
case "$path" in
  */jobs*) jq -c '.' "$GLAB_JOBS" ;;
  *pipelines*)
    ref=""; sha=""
    case "$path" in *ref=*) ref="${path##*ref=}"; ref="${ref%%&*}" ;; esac
    case "$path" in *sha=*) sha="${path##*sha=}"; sha="${sha%%&*}" ;; esac
    jq -c --arg ref "$ref" --arg sha "$sha" \
      '[ .[] | select($ref == "" or .ref == $ref)
             | select($sha == "" or .sha == $sha) ]' "$GLAB_PIPES"
    ;;
  *) echo "stub glab: unhandled api path: $path" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/glab"

export PATH="$bin:$PATH"

# --- a repo whose HEAD is the commit a release was cut from -------------------
new_repo() {
  local repo="$work/$1" origin="$2"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m seed
  git -C "$repo" remote add origin "$origin"
  echo "$repo"
}

gh_repo=$(new_repo widget "https://github.com/acme/widget.git")
sha=$(git -C "$gh_repo" rev-parse HEAD)

run() { bash "$status" --repo "$gh_repo" "$@"; }

runs_fixture() { printf '%s' "$1" > "$work/runs.json"; GH_RUNS="$work/runs.json"; export GH_RUNS; }
jobs_fixture() { printf '%s' "$1" > "$work/jobs.json"; GH_JOBS="$work/jobs.json"; export GH_JOBS; }
run_jobs_fixture() { printf '%s' "$2" > "$work/jobs-$1.json"; GH_JOBS_DIR="$work"; export GH_JOBS_DIR; }

# A run triggered by a published release: head_branch is the *tag*, head_sha is
# the commit the tag was cut from — the shape the release skill has to watch.
release_run() {
  cat <<JSON
[ { "id": 3040, "name": "Release", "path": ".github/workflows/release.yml",
    "event": "release", "head_branch": "v1.1.0", "head_sha": "$sha",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-07-28T21:44:21Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3040" } ]
JSON
}

# ===================== the release-triggered run is findable ==================
# The bug this test pins: watching a release-event run through a branch-scoped
# lookup reports `none`, because no run for this commit has head_branch=main.
runs_fixture "$(release_run)"
o=$(run --branch main)
[ "$(val PIPELINE_STATE "$o")" = "success" ] \
  || fail "a release-event run for HEAD should resolve even when the branch is main: $o"
[ "$(val PIPELINE_ID "$o")" = "3040" ] || fail "wrong run resolved: $o"
ok "release-event run (head_branch=tag) resolves for the commit under --branch main"

o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "success" ] \
  || fail "the same run should resolve with no ref argument at all: $o"
ok "release-event run resolves with no --branch argument"

# ===================== one run per workflow, so name the one you mean ========
# A pushed commit on GitHub has a run per workflow, not one pipeline. Naming the
# workflow is what makes the verdict about the release run and not a neighbor.
many_runs=$(cat <<JSON
[ { "id": 3040, "name": "Release", "path": ".github/workflows/release.yml",
    "event": "release", "head_branch": "v1.1.0", "head_sha": "$sha",
    "status": "in_progress", "conclusion": null,
    "created_at": "2026-07-28T21:44:21Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3040" },
  { "id": 3010, "name": "Test", "path": ".github/workflows/test.yml",
    "event": "push", "head_branch": "main", "head_sha": "$sha",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-07-28T21:17:11Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3010" } ]
JSON
)
runs_fixture "$many_runs"
o=$(run --workflow .github/workflows/release.yml)
[ "$(val PIPELINE_ID "$o")" = "3040" ] || fail "--workflow by path should pick the Release run: $o"
[ "$(val PIPELINE_STATE "$o")" = "running" ] || fail "expected the Release run's state: $o"
[ "$(val PIPELINE_WORKFLOW "$o")" = "Release" ] || fail "expected the workflow named: $o"
ok "--workflow <path> scopes the verdict to that workflow's run"

o=$(run --workflow release.yml)
[ "$(val PIPELINE_ID "$o")" = "3040" ] || fail "--workflow by file name should match too: $o"
ok "--workflow accepts the bare workflow file name"

o=$(run --workflow Release)
[ "$(val PIPELINE_ID "$o")" = "3040" ] || fail "--workflow by display name should match too: $o"
ok "--workflow accepts the workflow's display name"

o=$(run --workflow publish.yml)
[ "$(val PIPELINE_STATE "$o")" = "none" ] \
  || fail "a workflow with no run for this commit is none, not another workflow's run: $o"
ok "--workflow naming a workflow with no run for the commit reports none"

# Unscoped, the commit isn't settled while any of its runs is still in flight,
# and a red run outranks a green one — so the verdict isn't "whichever ran last".
o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "running" ] \
  || fail "with one run in flight the commit is not settled: $o"
ok "unscoped verdict reports in flight while any of the commit's runs is running"

settled_split=$(cat <<JSON
[ { "id": 3040, "name": "Lint", "path": ".github/workflows/lint.yml",
    "event": "push", "head_branch": "main", "head_sha": "$sha",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-07-28T21:44:21Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3040" },
  { "id": 3010, "name": "Test", "path": ".github/workflows/test.yml",
    "event": "push", "head_branch": "main", "head_sha": "$sha",
    "status": "completed", "conclusion": "failure",
    "created_at": "2026-07-28T21:17:11Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3010" } ]
JSON
)
runs_fixture "$settled_split"
jobs_fixture '[ { "name": "unit", "status": "completed", "conclusion": "failure",
                  "url": "https://github.com/acme/widget/actions/runs/3010/job/1" },
                { "name": "lint", "status": "completed", "conclusion": "success",
                  "url": "https://github.com/acme/widget/actions/runs/3010/job/2" } ]'
o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "failed" ] \
  || fail "a failed run should outrank a newer successful one: $o"
[ "$(val PIPELINE_ID "$o")" = "3010" ] || fail "expected the failed run: $o"
[ "$(val PIPELINE_WORKFLOW "$o")" = "Test" ] || fail "expected the failed workflow named: $o"
[[ "$(val PIPELINE_FAILED_JOBS "$o")" == *'"unit"'* ]] \
  || fail "failed jobs should come from the failed run: $o"
ok "unscoped verdict reports the commit's worst settled run, with its failed jobs"

# The fold is what `/anchor:pipeline` reports. A caller that gates on the forge's
# own checks asks for one run instead, and gets the commit's most recent.
o=$(run --single-run)
[ "$(val PIPELINE_ID "$o")" = "3040" ] || fail "--single-run should take the most recent run: $o"
[ "$(val PIPELINE_STATE "$o")" = "success" ] \
  || fail "--single-run reports that run's own state, not the fold: $o"
ok "--single-run reports the commit's most recent run, skipping the fold"

# A retried workflow leaves two runs for the same commit; the latest attempt is
# the one that counts, so an earlier red run must not outrank its green retry.
retried=$(cat <<JSON
[ { "id": 3099, "name": "Test", "path": ".github/workflows/test.yml",
    "event": "push", "head_branch": "main", "head_sha": "$sha",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-07-28T22:05:00Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3099" },
  { "id": 3010, "name": "Test", "path": ".github/workflows/test.yml",
    "event": "push", "head_branch": "main", "head_sha": "$sha",
    "status": "completed", "conclusion": "failure",
    "created_at": "2026-07-28T21:17:11Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3010" } ]
JSON
)
runs_fixture "$retried"
o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "success" ] \
  || fail "the latest run of a workflow should win over its earlier attempt: $o"
[ "$(val PIPELINE_ID "$o")" = "3099" ] || fail "expected the retry: $o"
ok "a workflow's latest run wins over its earlier attempt"

# When every run agrees, the newest speaks for the commit — so an unscoped watch
# right after a release names the release run rather than a green neighbor.
all_green=$(cat <<JSON
[ { "id": 3010, "name": "Deploy docs", "path": ".github/workflows/deploy-docs.yml",
    "event": "push", "head_branch": "main", "head_sha": "$sha",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-07-28T21:17:11Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3010" },
  { "id": 3040, "name": "Release", "path": ".github/workflows/release.yml",
    "event": "release", "head_branch": "v1.1.0", "head_sha": "$sha",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-07-28T21:44:21Z",
    "html_url": "https://github.com/acme/widget/actions/runs/3040" } ]
JSON
)
runs_fixture "$all_green"
o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "success" ] || fail "all runs green is success: $o"
[ "$(val PIPELINE_WORKFLOW "$o")" = "Release" ] \
  || fail "with the runs agreeing, the newest represents the commit: $o"
ok "with every run agreeing, the newest run represents the commit"

# ===================== job mode reads clean ==================================
# A one-shot read that finds what it was asked for has to exit 0 — a caller
# under `set -e` treats anything else as the read having failed.
runs_fixture "$(release_run)"
jobs_fixture '[ { "name": "publish", "status": "completed", "conclusion": "success",
                  "databaseId": 91,
                  "url": "https://github.com/acme/widget/actions/runs/3040/job/91" } ]'
o=$(run --workflow release.yml --job publish)
[ "$(val PIPELINE_JOB_STATE "$o")" = "success" ] || fail "expected the tracked job's state: $o"
[ "$(val PIPELINE_WORKFLOW "$o")" = "Release" ] || fail "expected the parent workflow named: $o"
run --workflow release.yml --job publish > /dev/null \
  || fail "a job-mode read that settled should exit 0"
ok "job mode reports the tracked job and exits 0"

# ===================== the breakdown covers every run, in every state ========
# The verdict is a fold, so on its own it can't say what ran. PIPELINE_RUNS is
# what the report tabulates: every workflow's run and every job under it,
# whatever state the commit is in.
runs_fixture "$settled_split"
run_jobs_fixture 3040 '[ { "name": "style", "status": "completed", "conclusion": "success",
                           "url": "https://github.com/acme/widget/actions/runs/3040/job/9" } ]'
run_jobs_fixture 3010 '[ { "name": "unit", "status": "completed", "conclusion": "failure",
                           "url": "https://github.com/acme/widget/actions/runs/3010/job/1" },
                         { "name": "e2e", "status": "completed", "conclusion": "skipped",
                           "url": "https://github.com/acme/widget/actions/runs/3010/job/2" } ]'
o=$(run)
b=$(val PIPELINE_RUNS "$o")
[ "$(jq -r 'length' <<<"$b")" = "2" ] \
  || fail "both of the commit's runs belong in the breakdown, not just the verdict's: $b"
[ "$(jq -r '.[] | select(.workflow == "Lint") | .state' <<<"$b")" = "success" ] \
  || fail "the run the fold passed over keeps its own state: $b"
[ "$(jq -r '.[] | select(.workflow == "Lint") | .jobs[0].name' <<<"$b")" = "style" ] \
  || fail "each run carries its own jobs: $b"
[ "$(jq -r '.[] | select(.workflow == "Test") | .jobs[] | select(.name == "e2e") | .state' <<<"$b")" = "skipped" ] \
  || fail "a skipped job is skipped, not failed: $b"
ok "PIPELINE_RUNS carries every run for the commit with its own jobs"

[[ "$(val PIPELINE_FAILED_JOBS "$o")" == *'"unit"'* ]] \
  || fail "the failed-jobs line still names the verdict run's failures: $o"
[[ "$(val PIPELINE_FAILED_JOBS "$o")" != *'"style"'* ]] \
  || fail "a passing job from another run is not a failed job: $o"
ok "PIPELINE_FAILED_JOBS still reports only the verdict run's failures"

# A green commit is the case the old output was silent about — the table needs
# rows there too, so the reader can see which workflows actually ran.
runs_fixture "$(release_run)"
run_jobs_fixture 3040 '[ { "name": "publish", "status": "completed", "conclusion": "success",
                           "url": "https://github.com/acme/widget/actions/runs/3040/job/9" } ]'
o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "success" ] || fail "expected a green commit: $o"
[ "$(jq -r '.[0].jobs[0].name' <<<"$(val PIPELINE_RUNS "$o")")" = "publish" ] \
  || fail "a green commit still gets a breakdown: $o"
ok "the breakdown is emitted on success, not only on failure"

# ===================== no run for this commit ================================
runs_fixture '[]'
o=$(run)
[ "$(val PIPELINE_STATE "$o")" = "none" ] || fail "no runs for the commit is none: $o"
[ -z "$(val PIPELINE_RUNS "$o")" ] \
  || fail "with no pipeline there is nothing to tabulate: $o"
ok "a commit with no runs reports none, with no breakdown"

# ===================== GitLab: a tag pipeline resolves too ===================
gl_repo=$(new_repo gadget "https://gitlab.example.com/acme/gadget.git")
gl_sha=$(git -C "$gl_repo" rev-parse HEAD)
cat > "$work/pipes.json" <<JSON
[ { "id": 771, "sha": "$gl_sha", "ref": "v1.1.0", "status": "success",
    "web_url": "https://gitlab.example.com/acme/gadget/-/pipelines/771" } ]
JSON
export GLAB_PIPES="$work/pipes.json"
GLAB_ARGS_FILE="$work/glab-args.txt"; export GLAB_ARGS_FILE

o=$(bash "$status" --repo "$gl_repo" --branch main)
[ "$(val PIPELINE_FORGE "$o")" = "gitlab" ] || fail "expected the gitlab path: $o"
[ "$(val PIPELINE_STATE "$o")" = "success" ] \
  || fail "a tag pipeline for HEAD should resolve under --branch main: $o"
[ "$(val PIPELINE_ID "$o")" = "771" ] || fail "wrong pipeline resolved: $o"
ok "GitLab tag pipeline resolves for the commit under --branch main"

grep -q 'ref=' "$GLAB_ARGS_FILE" \
  && fail "the pipelines lookup must not narrow by ref: $(cat "$GLAB_ARGS_FILE")"
ok "the GitLab lookup asks by sha, not by ref"

# ===================== GitLab: one pipeline, jobs grouped by stage ===========
cat > "$work/gl-jobs.json" <<'JSON'
[ { "name": "build", "stage": "build", "status": "success",
    "web_url": "https://gitlab.example.com/acme/gadget/-/jobs/1" },
  { "name": "deploy", "stage": "deploy", "status": "manual",
    "web_url": "https://gitlab.example.com/acme/gadget/-/jobs/2" } ]
JSON
export GLAB_JOBS="$work/gl-jobs.json"

o=$(bash "$status" --repo "$gl_repo" --branch main)
b=$(val PIPELINE_RUNS "$o")
[ "$(jq -r 'length' <<<"$b")" = "1" ] || fail "GitLab has one pipeline per commit: $b"
[ "$(jq -r '.[0].jobs[] | select(.name == "deploy") | .stage' <<<"$b")" = "deploy" ] \
  || fail "a GitLab job carries the stage that groups the table: $b"
[ "$(jq -r '.[0].jobs[] | select(.name == "deploy") | .state' <<<"$b")" = "manual" ] \
  || fail "a job awaiting a manual action is manual, not pending: $b"
ok "the GitLab breakdown carries each job's stage and state"

# A red pipeline still derives its failed jobs from the same breakdown — one
# jobs call, not two.
cat > "$work/pipes.json" <<JSON
[ { "id": 772, "sha": "$gl_sha", "ref": "main", "status": "failed",
    "web_url": "https://gitlab.example.com/acme/gadget/-/pipelines/772" } ]
JSON
cat > "$work/gl-jobs.json" <<'JSON'
[ { "name": "test", "stage": "test", "status": "failed",
    "web_url": "https://gitlab.example.com/acme/gadget/-/jobs/3" },
  { "name": "lint", "stage": "test", "status": "success",
    "web_url": "https://gitlab.example.com/acme/gadget/-/jobs/4" } ]
JSON
o=$(bash "$status" --repo "$gl_repo" --branch main)
f=$(val PIPELINE_FAILED_JOBS "$o")
[ "$(jq -r 'length' <<<"$f")" = "1" ] || fail "only the failed job is a failed job: $f"
[ "$(jq -r '.[0].stage' <<<"$f")" = "test" ] || fail "the GitLab failed-job shape keeps its stage: $f"
ok "GitLab failed jobs are derived from the breakdown, stage intact"

echo "all pipeline-status tests passed"
