#!/usr/bin/env bash
# Report the pipeline status for a commit on a forge, or watch it until it
# reaches a terminal state. Forge-agnostic: it picks gh (GitHub Actions) or glab
# (GitLab CI/CD) by the origin remote, resolves the pipeline for a *commit*, and
# prints a normalized verdict on stdout so the caller acts on one command's
# output — no separate file read, no orchestration to narrate.
#
# Resolution is by commit sha, never by ref: a run triggered by a published
# release or a tag push carries the tag as its head_branch, so a ref-scoped
# lookup ("runs on main") misses it even though the run is for that commit.
# --branch names the ref whose commit to resolve, not a filter on the result.
#
# Why a script (not skill prose): the watch loop sleeps and polls, and the GitLab
# path leans on `glab api projects/:fullpath/...` (the forge cookbook's idiom).
# Folding the whole watch into one background call keeps the skill a single
# launch-and-read rather than a narrated poll loop.
#
# Output lines (KEY=value, read from stdout):
#   PIPELINE_FORGE=<github|gitlab|none>
#   PIPELINE_STATE=<state>     normalized — terminal: success failed canceled
#                              skipped manual; in-flight: running pending;
#                              none (no pipeline for this commit yet);
#                              absent (origin isn't a recognized forge)
#   PIPELINE_URL=<web url>     the pipeline's web page (may be empty)
#   PIPELINE_ID=<id>           pipeline / run id (may be empty)
#   PIPELINE_SHA=<sha>         the commit watched
#   PIPELINE_BRANCH=<branch>   the ref the commit was resolved from
#   PIPELINE_WORKFLOW=<name>   (GitHub) the workflow whose run the verdict is
#                              about — a commit has one run per workflow
#   PIPELINE_TIMEOUT=1         (watch mode only) the watch ceiling was hit before
#                              a terminal state — PIPELINE_STATE holds the last seen
#   PIPELINE_RUNS=<json>       every run for the commit with its jobs, in every
#                              state: [{id, workflow, state, url,
#                              jobs:[{name, stage, state, url}]}]. This is what
#                              the report tabulates; PIPELINE_STATE stays the
#                              headline verdict. Absent when there's no pipeline.
#   PIPELINE_FAILED_JOBS=<json> (state==failed only) [{name, ...}] compact array
#
# With --job <name>, the script tracks a single named job inside the pipeline
# instead of the pipeline as a whole — so polling for one job (e.g. a Terraform
# plan job that gates the rest) is the same launch-and-read, no hand-written
# loop. It adds these lines (and PIPELINE_STATE/PIPELINE_URL describe the parent
# pipeline for context):
#   PIPELINE_JOB_NAME=<name>   the job tracked
#   PIPELINE_JOB_STATE=<state> normalized like PIPELINE_STATE; none == no job by
#                              that name in the pipeline yet
#   PIPELINE_JOB_URL=<web url> the job's web page (may be empty)
#
# Modes:
#   pipeline-status.sh                 one-shot status for the commit at HEAD
#   pipeline-status.sh --watch         poll until terminal (or the ceiling), then emit
#   pipeline-status.sh --repo <path>              target a checkout other than the cwd repo
#   pipeline-status.sh --worktree <path>          target a flow-owned isolated worktree
#   pipeline-status.sh --branch <b> --sha <sha>   target an explicit ref/commit
#   pipeline-status.sh --workflow <name>          scope to one GitHub workflow
#                                              (path, file name, or display name)
#   pipeline-status.sh --single-run               report the commit's most recent
#                                              run instead of folding its runs
#   pipeline-status.sh --job <name>               track one named job, not the pipeline
#   pipeline-status.sh --job <name> --watch       poll that job until it settles
#   pipeline-status.sh --pipeline <id> --job <name>   target a pipeline by id directly
#                                              (skips commit→pipeline resolution)
#
# Tunables (flags override env, env overrides default):
#   --interval <s>  / PIPELINE_POLL_INTERVAL   poll cadence            (default 15)
#   --timeout  <s>  / PIPELINE_WATCH_TIMEOUT   watch ceiling           (default 1800)
#                     PIPELINE_APPEAR_TIMEOUT  wait for a pipeline to
#                                              first appear for the sha (default 120)

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"

POLL_INTERVAL="${PIPELINE_POLL_INTERVAL:-15}"
WATCH_TIMEOUT="${PIPELINE_WATCH_TIMEOUT:-1800}"
APPEAR_TIMEOUT="${PIPELINE_APPEAR_TIMEOUT:-120}"

mode="status"
branch=""
sha=""
job=""
workflow=""
single_run=""
pipeline_id=""
CTX_REPO=""
CTX_WORKTREE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)    mode="watch"; shift ;;
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
    --branch)   branch="${2:?--branch needs a value}"; shift 2 ;;
    --sha)      sha="${2:?--sha needs a value}"; shift 2 ;;
    --workflow)   workflow="${2:?--workflow needs a value}"; shift 2 ;;
    --single-run) single_run=1; shift ;;
    --job)      job="${2:?--job needs a value}"; shift 2 ;;
    --pipeline) pipeline_id="${2:?--pipeline needs a value}"; shift 2 ;;
    --interval) POLL_INTERVAL="${2:?--interval needs a value}"; shift 2 ;;
    --timeout)  WATCH_TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    *) echo "pipeline-status.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# Retarget onto an explicit --repo checkout before any git/forge call; the
# branch/sha defaults below then read from the target repo, not the cwd.
ctx_resolve_repo

[[ -n "$branch" ]] || branch=$(git rev-parse --abbrev-ref HEAD)
# Peel to a commit so an annotated tag passed as --branch resolves to what it
# points at rather than to the tag object.
[[ -n "$sha" ]]    || sha=$(git rev-parse "${branch}^{commit}")

# Each forge's state vocabulary → the normalized one, as a jq def. Runs and jobs
# answer with the same vocabulary on both forges, so every probe below shares
# one mapping instead of restating it.
JQ_GH_NORMALIZE='
  def normalize:
    if .status != "completed"
    then (if .status == "queued" then "pending" else "running" end)
    else ( { "success":"success", "failure":"failed", "timed_out":"failed",
             "startup_failure":"failed", "cancelled":"canceled",
             "skipped":"skipped", "action_required":"manual",
             "neutral":"success", "stale":"failed" }[.conclusion] // "failed" )
    end;
'
# GitLab statuses already match the normalized vocabulary for terminal states;
# the map collapses the various in-flight ones to running/pending.
JQ_GL_NORMALIZE='
  def normalize:
    ( { "success":"success", "failed":"failed", "canceled":"canceled",
        "skipped":"skipped", "manual":"manual", "running":"running" }[.status]
      // "pending" );
'

detect_forge() {
  local url
  url=$(git remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) echo "github" ;;
    *gitlab*)     echo "gitlab" ;;
    *)            echo "" ;;
  esac
}

# Print a compact JSON record {state,url,id,sha,workflow} for the pipeline at
# commit $sha, or {"state":"none"} when none exists yet. GitHub conclusions fold
# into the normalized vocabulary; GitLab statuses already use it.
#
# GitHub answers with one run per workflow rather than a single pipeline, so the
# commit's verdict is a fold over them: keep each workflow's latest attempt (a
# retry supersedes the run it replaced), then let the least-settled/worst state
# stand for the commit — a commit isn't green while one workflow is still
# running, and isn't green at all if another went red. --workflow narrows to the
# one workflow the caller means, which is how a release watch tracks the release
# run and not a neighbor that happens to share the commit.
#
# --single-run opts out of the fold and reports the commit's most recent run.
# A caller that gates on the forge's own merge checks wants this: it asks the
# helper for one run's state, and leaves "is every check green" to the forge.
probe_github() {
  local runs
  runs=$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null) || runs=""
  [[ -n "$runs" ]] || { echo '{"state":"none"}'; return; }
  jq -c --arg wf "$workflow" --arg single "$single_run" "$JQ_GH_NORMALIZE"'
    def severity:
      { "running":0, "pending":1, "failed":2, "canceled":3,
        "manual":4, "success":5, "skipped":6 }[.] // 7;
    ( [ .workflow_runs[]
        | select($wf == "" or .path == $wf
                 or (.path | split("/") | last) == $wf or .name == $wf) ]
      | group_by(.path)
      | map(max_by([.created_at, .id]) | . + {state: normalize}) ) as $latest
    | ( [ $latest[] | .state | severity ] | min ) as $worst
    | ( if $single == "1" then $latest
        else [ $latest[] | select((.state | severity) == $worst) ] end
        | max_by([.created_at, .id]) ) as $r
    | if $r == null then {state:"none"}
      else {
        id:       ($r.id | tostring),
        url:      $r.html_url,
        sha:      $r.head_sha,
        workflow: $r.name,
        state:    $r.state
      } end' <<<"$runs"
}

# GitLab has one pipeline per commit, so --workflow has nothing to narrow here —
# the commit's pipeline already is the one the CI config describes.
probe_gitlab() {
  local pipes
  pipes=$(glab api "projects/:fullpath/pipelines?sha=$sha&per_page=1" 2>/dev/null) || pipes=""
  [[ -n "$pipes" ]] || { echo '{"state":"none"}'; return; }
  jq -c "$JQ_GL_NORMALIZE"'
    .[0] as $p
    | if $p == null then {state:"none"}
      else {
        id:    ($p.id | tostring),
        url:   $p.web_url,
        sha:   $p.sha,
        state: ($p | normalize)
      } end' <<<"$pipes"
}

probe() {
  case "$forge" in
    github) probe_github ;;
    gitlab) probe_gitlab ;;
  esac
}

is_terminal() {
  case "$1" in
    success|failed|canceled|skipped|manual) return 0 ;;
    *) return 1 ;;
  esac
}

jobs_github() {
  local id="$1" jobs
  jobs=$(gh run view "$id" --json jobs 2>/dev/null) || { echo '[]'; return; }
  jq -c "$JQ_GH_NORMALIZE"'
    [ .jobs[] | {name, stage: "", url, state: normalize} ]' <<<"$jobs"
}

jobs_gitlab() {
  local id="$1" jobs
  jobs=$(glab api "projects/:fullpath/pipelines/$id/jobs?per_page=100" 2>/dev/null) || { echo '[]'; return; }
  jq -c "$JQ_GL_NORMALIZE"'
    [ .[] | {name, stage, url: .web_url, state: normalize} ]' <<<"$jobs"
}

# Every run for the commit, each with its jobs:
#   [{id, workflow, state, url, jobs: [{name, stage, state, url}]}]
#
# This is what the report tabulates, so it covers every state rather than only
# the failures: a green report says which workflows ran, and a blocked one says
# which job holds the gate. On GitHub that means all of the commit's runs, not
# just the one the fold's verdict came from — the fold answers "is it green",
# the breakdown answers "what ran".
#
# Built once, when the result is emitted, rather than per poll: a watch costs
# one extra round of calls, not one per iteration.
runs_breakdown_github() {
  local list acc='[]' rec rid runs
  runs=$(gh api "repos/{owner}/{repo}/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null) || { echo '[]'; return; }
  list=$(jq -c --arg wf "$workflow" "$JQ_GH_NORMALIZE"'
    [ .workflow_runs[]
      | select($wf == "" or .path == $wf
               or (.path | split("/") | last) == $wf or .name == $wf) ]
    | group_by(.path)
    | map(max_by([.created_at, .id])
          | {id: (.id | tostring), workflow: .name, url: .html_url, state: normalize})
    | sort_by(.workflow)' <<<"$runs")
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    rid=$(jq -r '.id' <<<"$rec")
    acc=$(jq -c --argjson r "$rec" --argjson j "$(jobs_github "$rid")" \
             '. + [ $r + {jobs: $j} ]' <<<"$acc")
  done < <(jq -c '.[]' <<<"$list")
  echo "$acc"
}

# One pipeline per commit on GitLab, so the breakdown is that pipeline plus its
# jobs — the stage each job belongs to is what groups the table's rows.
runs_breakdown_gitlab() {
  local id="$1" state="$2" url="$3"
  jq -nc --arg id "$id" --arg state "$state" --arg url "$url" \
     --argjson jobs "$(jobs_gitlab "$id")" \
     '[ {id: $id, workflow: "", state: $state, url: $url, jobs: $jobs} ]'
}

runs_breakdown() {
  case "$forge" in
    github) runs_breakdown_github ;;
    gitlab) runs_breakdown_gitlab "$@" ;;
    *) echo '[]' ;;
  esac
}

# The failed jobs of the run the verdict came from, read back out of the
# breakdown so a red report costs no extra call. GitLab carries the stage;
# GitHub has none to carry.
failed_jobs() {
  local breakdown="$1" id="$2"
  case "$forge" in
    github) jq -c --arg id "$id" \
              '[ .[] | select(.id == $id) | .jobs[]
                 | select(.state == "failed") | {name, url} ]' <<<"$breakdown" ;;
    gitlab) jq -c '[ .[] | .jobs[]
                     | select(.state == "failed") | {name, stage, url} ]' <<<"$breakdown" ;;
    *) echo '[]' ;;
  esac
}

# Print a compact JSON record {state,url,name} for one named job in a pipeline,
# or {"state":"none"} when no job by that name exists yet (it may not have been
# created — earlier stages still running). Match is on the exact job name; when a
# name repeats (a retried job), the most recent attempt wins.
probe_job_github() {
  local runid="$1" jobname="$2" jobs
  jobs=$(gh run view "$runid" --json jobs 2>/dev/null) || jobs=""
  [[ -n "$jobs" ]] || { echo '{"state":"none"}'; return; }
  jq -c --arg name "$jobname" "$JQ_GH_NORMALIZE"'
    ( [ .jobs[] | select(.name == $name) ] | sort_by(.databaseId) | last ) as $j
    | if $j == null then {state:"none"}
      else {
        name:  $j.name,
        url:   $j.url,
        state: ($j | normalize)
      } end' <<<"$jobs"
}

probe_job_gitlab() {
  local pid="$1" jobname="$2" jobs
  jobs=$(glab api "projects/:fullpath/pipelines/$pid/jobs?per_page=100" 2>/dev/null) || jobs=""
  [[ -n "$jobs" ]] || { echo '{"state":"none"}'; return; }
  jq -c --arg name "$jobname" "$JQ_GL_NORMALIZE"'
    ( [ .[] | select(.name == $name) ] | sort_by(.id) | last ) as $j
    | if $j == null then {state:"none"}
      else {
        name:  $j.name,
        url:   $j.web_url,
        state: ($j | normalize)
      } end' <<<"$jobs"
}

probe_job() {
  case "$forge" in
    github) probe_job_github "$1" "$2" ;;
    gitlab) probe_job_gitlab "$1" "$2" ;;
  esac
}

emit() {
  local state="$1" url="$2" id="$3" wf="$4" timed_out="${5:-}"
  local breakdown=""
  [[ -n "$id" ]] && breakdown=$(runs_breakdown "$id" "$state" "$url")
  echo "PIPELINE_FORGE=$forge"
  echo "PIPELINE_STATE=$state"
  echo "PIPELINE_URL=$url"
  echo "PIPELINE_ID=$id"
  echo "PIPELINE_SHA=$sha"
  echo "PIPELINE_BRANCH=$branch"
  echo "PIPELINE_WORKFLOW=$wf"
  if [[ -n "$timed_out" ]]; then echo "PIPELINE_TIMEOUT=1"; fi
  if [[ -n "$breakdown" ]]; then
    echo "PIPELINE_RUNS=$breakdown"
    if [[ "$state" == "failed" ]]; then
      echo "PIPELINE_FAILED_JOBS=$(failed_jobs "$breakdown" "$id")"
    fi
  fi
}

# Job mode: the parent pipeline keys give context (state/url/id), then the job
# keys carry the thing actually being tracked.
emit_job() {
  local jstate="$1" jurl="$2" pstate="$3" purl="$4" id="$5" pwf="$6" timed_out="${7:-}"
  echo "PIPELINE_FORGE=$forge"
  echo "PIPELINE_STATE=$pstate"
  echo "PIPELINE_URL=$purl"
  echo "PIPELINE_ID=$id"
  echo "PIPELINE_SHA=$sha"
  echo "PIPELINE_BRANCH=$branch"
  echo "PIPELINE_WORKFLOW=$pwf"
  echo "PIPELINE_JOB_NAME=$job"
  echo "PIPELINE_JOB_STATE=$jstate"
  echo "PIPELINE_JOB_URL=$jurl"
  # An `if`, not a `&&` list: as the closing statement it would hand the caller a
  # 1 return on the ordinary no-timeout path, which `set -e` turns into exit 1.
  if [[ -n "$timed_out" ]]; then echo "PIPELINE_TIMEOUT=1"; fi
}

forge=$(detect_forge)
if [[ -z "$forge" ]]; then
  echo "PIPELINE_FORGE=none"
  echo "PIPELINE_STATE=absent"
  echo "PIPELINE_SHA=$sha"
  echo "PIPELINE_BRANCH=$branch"
  exit 0
fi

# Job mode: track one named job inside the pipeline. One pass for status; poll
# until the job settles for watch. Resolving the parent pipeline each iteration
# (unless pinned by --pipeline) lets watch start before the pipeline exists.
if [[ -n "$job" ]]; then
  elapsed=0
  appeared=0
  timed_out=""
  while :; do
    if [[ -n "$pipeline_id" ]]; then
      pid="$pipeline_id"; pstate=""; purl=""; pwf=""
    else
      prec=$(probe)
      pid=$(jq -r '.id // ""' <<<"$prec")
      pstate=$(jq -r '.state' <<<"$prec")
      purl=$(jq -r '.url // ""' <<<"$prec")
      pwf=$(jq -r '.workflow // ""' <<<"$prec")
    fi

    if [[ -n "$pid" ]]; then
      jrec=$(probe_job "$pid" "$job")
    else
      jrec='{"state":"none"}'
    fi
    jstate=$(jq -r '.state' <<<"$jrec")
    jurl=$(jq -r '.url // ""' <<<"$jrec")

    [[ "$mode" == "status" ]] && break

    if [[ "$jstate" == "none" ]]; then
      # No job by this name yet — earlier stages may still be running, or the
      # pipeline itself hasn't appeared. Bound the wait for it to show up.
      if (( appeared == 0 && elapsed >= APPEAR_TIMEOUT )); then
        break
      fi
    else
      appeared=1
      is_terminal "$jstate" && break
    fi

    if (( elapsed >= WATCH_TIMEOUT )); then
      timed_out=1
      break
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
  done

  emit_job "$jstate" "$jurl" "$pstate" "$purl" "$pid" "$pwf" "$timed_out"
  exit 0
fi

if [[ "$mode" == "status" ]]; then
  rec=$(probe)
  emit "$(jq -r '.state' <<<"$rec")" \
       "$(jq -r '.url // ""' <<<"$rec")" \
       "$(jq -r '.id // ""' <<<"$rec")" \
       "$(jq -r '.workflow // ""' <<<"$rec")"
  exit 0
fi

# Watch mode: poll until terminal, the watch ceiling, or (if a pipeline never
# appears for this commit) the appearance window.
elapsed=0
appeared=0
timed_out=""
while :; do
  rec=$(probe)
  state=$(jq -r '.state' <<<"$rec")
  url=$(jq -r '.url // ""' <<<"$rec")
  id=$(jq -r '.id // ""' <<<"$rec")
  wf=$(jq -r '.workflow // ""' <<<"$rec")

  if [[ "$state" == "none" ]]; then
    # No pipeline for this commit yet. Give CI a bounded window to create one
    # (path filters or a CI-less repo mean it may never appear), then give up.
    if (( appeared == 0 && elapsed >= APPEAR_TIMEOUT )); then
      break
    fi
  else
    appeared=1
    is_terminal "$state" && break
  fi

  if (( elapsed >= WATCH_TIMEOUT )); then
    timed_out=1
    break
  fi
  sleep "$POLL_INTERVAL"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

emit "$state" "$url" "$id" "$wf" "$timed_out"
