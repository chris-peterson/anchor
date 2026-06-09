#!/usr/bin/env bash
# Report the pipeline status for a commit on a forge, or watch it until it
# reaches a terminal state. Forge-agnostic: it picks gh (GitHub Actions) or glab
# (GitLab CI/CD) by the origin remote, resolves the pipeline for a specific
# branch + commit, and prints a normalized verdict on stdout so the caller acts
# on one command's output — no separate file read, no orchestration to narrate.
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
#   PIPELINE_BRANCH=<branch>   the branch watched
#   PIPELINE_TIMEOUT=1         (watch mode only) the watch ceiling was hit before
#                              a terminal state — PIPELINE_STATE holds the last seen
#   PIPELINE_FAILED_JOBS=<json> (state==failed only) [{name, ...}] compact array
#
# Modes:
#   pipeline-status.sh                 one-shot status for HEAD on the current branch
#   pipeline-status.sh --watch         poll until terminal (or the ceiling), then emit
#   pipeline-status.sh --branch <b> --sha <sha>   target an explicit ref/commit
#
# Tunables (flags override env, env overrides default):
#   --interval <s>  / PIPELINE_POLL_INTERVAL   poll cadence            (default 15)
#   --timeout  <s>  / PIPELINE_WATCH_TIMEOUT   watch ceiling           (default 1800)
#                     PIPELINE_APPEAR_TIMEOUT  wait for a pipeline to
#                                              first appear for the sha (default 120)

set -euo pipefail

POLL_INTERVAL="${PIPELINE_POLL_INTERVAL:-15}"
WATCH_TIMEOUT="${PIPELINE_WATCH_TIMEOUT:-1800}"
APPEAR_TIMEOUT="${PIPELINE_APPEAR_TIMEOUT:-120}"

mode="status"
branch=""
sha=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)    mode="watch"; shift ;;
    --branch)   branch="${2:?--branch needs a value}"; shift 2 ;;
    --sha)      sha="${2:?--sha needs a value}"; shift 2 ;;
    --interval) POLL_INTERVAL="${2:?--interval needs a value}"; shift 2 ;;
    --timeout)  WATCH_TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    *) echo "pipeline-status.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$branch" ]] || branch=$(git rev-parse --abbrev-ref HEAD)
[[ -n "$sha" ]]    || sha=$(git rev-parse HEAD)

detect_forge() {
  local url
  url=$(git remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) echo "github" ;;
    *gitlab*)     echo "gitlab" ;;
    *)            echo "" ;;
  esac
}

# Print a compact JSON record {state,url,id,sha} for the latest pipeline whose
# commit == $sha, or {"state":"none"} when none exists yet. GitHub conclusions
# fold into the normalized vocabulary; GitLab statuses already use it.
probe_github() {
  local runs
  runs=$(gh run list --branch "$branch" --limit 25 \
           --json databaseId,status,conclusion,headSha,url 2>/dev/null) || runs=""
  [[ -n "$runs" ]] || { echo '{"state":"none"}'; return; }
  jq -c --arg sha "$sha" '
    ( [ .[] | select(.headSha == $sha) ] | .[0] ) as $r
    | if $r == null then {state:"none"}
      else {
        id:  ($r.databaseId | tostring),
        url: $r.url,
        sha: $r.headSha,
        state:
          ( if $r.status != "completed"
            then (if $r.status == "queued" then "pending" else "running" end)
            else ( { "success":"success", "failure":"failed", "timed_out":"failed",
                     "startup_failure":"failed", "cancelled":"canceled",
                     "skipped":"skipped", "action_required":"manual",
                     "neutral":"success", "stale":"failed" }[$r.conclusion] // "failed" )
            end )
      } end' <<<"$runs"
}

probe_gitlab() {
  local pipes
  pipes=$(glab api "projects/:fullpath/pipelines?ref=$branch&sha=$sha&per_page=1" 2>/dev/null) || pipes=""
  [[ -n "$pipes" ]] || { echo '{"state":"none"}'; return; }
  jq -c '
    .[0] as $p
    | if $p == null then {state:"none"}
      else {
        id:  ($p.id | tostring),
        url: $p.web_url,
        sha: $p.sha,
        # GitLab statuses already match the normalized vocabulary for terminal
        # states; collapse the various in-flight states to running/pending.
        state:
          ( { "success":"success", "failed":"failed", "canceled":"canceled",
              "skipped":"skipped", "manual":"manual", "running":"running" }[$p.status]
            // "pending" )
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

failed_jobs_github() {
  local id="$1" jobs
  jobs=$(gh run view "$id" --json jobs 2>/dev/null) || { echo '[]'; return; }
  jq -c '[ .jobs[]
           | select(.conclusion == "failure" or .conclusion == "timed_out"
                    or .conclusion == "startup_failure")
           | {name, url} ]' <<<"$jobs"
}

failed_jobs_gitlab() {
  local id="$1" jobs
  jobs=$(glab api "projects/:fullpath/pipelines/$id/jobs?per_page=100" 2>/dev/null) || { echo '[]'; return; }
  jq -c '[ .[] | select(.status == "failed") | {name, stage, url: .web_url} ]' <<<"$jobs"
}

failed_jobs() {
  case "$forge" in
    github) failed_jobs_github "$1" ;;
    gitlab) failed_jobs_gitlab "$1" ;;
    *) echo '[]' ;;
  esac
}

emit() {
  local state="$1" url="$2" id="$3" timed_out="${4:-}"
  echo "PIPELINE_FORGE=$forge"
  echo "PIPELINE_STATE=$state"
  echo "PIPELINE_URL=$url"
  echo "PIPELINE_ID=$id"
  echo "PIPELINE_SHA=$sha"
  echo "PIPELINE_BRANCH=$branch"
  [[ -n "$timed_out" ]] && echo "PIPELINE_TIMEOUT=1"
  if [[ "$state" == "failed" && -n "$id" ]]; then
    echo "PIPELINE_FAILED_JOBS=$(failed_jobs "$id")"
  fi
}

forge=$(detect_forge)
if [[ -z "$forge" ]]; then
  echo "PIPELINE_FORGE=none"
  echo "PIPELINE_STATE=absent"
  echo "PIPELINE_SHA=$sha"
  echo "PIPELINE_BRANCH=$branch"
  exit 0
fi

if [[ "$mode" == "status" ]]; then
  rec=$(probe)
  emit "$(jq -r '.state' <<<"$rec")" \
       "$(jq -r '.url // ""' <<<"$rec")" \
       "$(jq -r '.id // ""' <<<"$rec")"
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

emit "$state" "$url" "$id" "$timed_out"
