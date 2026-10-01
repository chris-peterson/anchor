#!/usr/bin/env bash
# Read everything /anchor:merge decides on before it lands a change request —
# the CR, whether the checkout matches it, the five gates, and the merge method
# the forge's settings resolve to — in one pass, as a KEY=value block.
#
# Why a script (not skill prose): every gate is a deterministic read of a forge
# field, and each forge spells them differently. Left to the skill, a merge was a
# dozen bespoke `gh` / `glab` / `jq` calls re-derived per run, each one a line the
# user watched scroll past. What the skill keeps is the part that needs a person:
# asking, and deciding what to do about a gate that blocks.
#
# This script only reads. Clearing the draft flag is scripts/mark-ready.sh, the
# merge and its cleanup are scripts/merge.sh, and watching an in-flight pipeline
# is scripts/pipeline-status.sh --watch, after which the caller runs this again
# so every gate is read fresh rather than trusted from before the wait.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>
#   MERGE_FORGE=<github|gitlab>
#   CR_REF=<#128|!42>           the CR as the forge writes a reference to it
#   CR_NUMBER=<n>
#   CR_URL=<web url>
#   CR_TITLE=<title>
#   CR_STATE=<open|merged|closed>
#   CR_HEAD_SHA=<sha>           the head the merge is guarded on
#   CR_SOURCE_BRANCH=<branch>
#   CR_TARGET_BRANCH=<branch>
#   CR_COMMITS=<n>              commits on the CR, for "preserves N commits"
#   LOCAL_STATE=<ok|dirty|head-mismatch>
#   LOCAL_HEAD_SHA=<sha>
#
#   Gates, in the order they are checked. Each has a state and a short detail
#   fit for the gate table's State column.
#   GATE_DRAFT=<clear|draft>
#   GATE_MERGEABLE=<ok|conflicts|behind|unknown|blocked>
#   GATE_MERGEABLE_DETAIL=<the forge's own value>
#   GATE_PIPELINE=<success|running|pending|failed|canceled|manual|skipped|none|unreachable|absent>
#   GATE_PIPELINE_DETAIL=<e.g. "3/3 jobs on abc1234">
#   PIPELINE_URL=<url>          passed through from pipeline-status.sh
#   PIPELINE_FAILED_JOBS=<json> the failed or canceled jobs, or the failing checks
#   PIPELINE_ERROR=<text>       passed through when the pipeline was unreachable
#   GATE_APPROVALS=<met|none|missing|changes-requested>
#   GATE_APPROVALS_DETAIL=<e.g. "1 required, 0 left; approved by @ana">
#   GATE_THREADS=<resolved|open>
#   GATE_THREADS_DETAIL=<e.g. "2 unresolved">
#   THREADS=<json>              [{path, line, author, body}] for open threads
#   GATE_BLOCKING=<gate|>       the first gate that isn't passing, empty when
#                               none: state, local, draft, mergeable, pipeline,
#                               approvals, threads. Reading stops at the first
#                               one, except threads: open threads are the
#                               author's call, so the method below is still read.
#
#   The merge method, resolved from the forge's settings:
#   MERGE_METHOD=<merge|rebase|squash|ff|rebase_merge>
#   MERGE_SQUASH=<0|1>
#   MERGE_METHOD_LABEL=<phrase>     what the confirmation prompt calls it
#   MERGE_METHOD_SETTING=<phrase>   the setting that moved it off the merge-commit
#                                   default; empty when nothing did
#
# A gate that doesn't apply passes: `none` pipeline, `none` approvals.
#
# On a failure it prints MERGE_GATES_ERROR=<message> on stderr and exits
# non-zero; an authentication failure is marked MERGE_GATES_AUTH=1 so the caller
# asks for fresh credentials instead of retrying.
#
# Usage:
#   merge-gates.sh                         the CR for the current branch
#   merge-gates.sh --cr 128                a named CR
#   merge-gates.sh --repo /path/to/checkout

set -euo pipefail

here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/resolve-context.sh
source "$here/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$here/lib/forge-url.sh"

CTX_REPO=""
cr=""
# GitHub computes mergeability lazily and answers UNKNOWN until it has; a short
# re-read settles most of those without handing the user a gate that says nothing.
MERGEABLE_RETRIES="${MERGE_GATES_MERGEABLE_RETRIES:-3}"
MERGEABLE_DELAY="${MERGE_GATES_MERGEABLE_DELAY:-2}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr)   cr="${2:?--cr needs a value}"; shift 2 ;;
    --repo) CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) echo "MERGE_GATES_ERROR=unrecognized argument: $1" >&2; exit 64 ;;
  esac
done

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

forge=$(anchor_forge_of_origin)
case "$forge" in
  github|gitlab) ;;
  *) echo "MERGE_GATES_ERROR=origin is neither GitHub nor GitLab" >&2; exit 69 ;;
esac
echo "MERGE_FORGE=$forge"

# die <what> <output> — report a forge read that failed, flagging auth apart.
die() {
  echo "MERGE_GATES_ERROR=$1: $2" >&2
  if grep -qiE '401|403|unauthori[sz]ed|forbidden|authentication|not logged in|gh auth login|glab auth login' <<<"$2"; then
    echo "MERGE_GATES_AUTH=1" >&2
  fi
  exit 70
}

emit() { printf '%s=%s\n' "$1" "$2"; }

# --- The CR -----------------------------------------------------------------

if [[ "$forge" == github ]]; then
  fields=number,url,title,state,isDraft,headRefOid,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,commits,statusCheckRollup
  view=$(gh pr view ${cr:+"$cr"} --json "$fields" 2>&1) || die "could not read the CR" "$view"
  number=$(jq -r '.number' <<<"$view")
  cr_ref="#$number"
  url=$(jq -r '.url' <<<"$view")
  title=$(jq -r '.title' <<<"$view")
  state=$(jq -r '.state | ascii_downcase' <<<"$view")
  draft=$(jq -r '.isDraft' <<<"$view")
  head_sha=$(jq -r '.headRefOid' <<<"$view")
  source_branch=$(jq -r '.headRefName' <<<"$view")
  target_branch=$(jq -r '.baseRefName' <<<"$view")
  commits=$(jq -r '.commits | length' <<<"$view")
else
  view=$(glab mr view ${cr:+"$cr"} --output json 2>&1) || die "could not read the CR" "$view"
  number=$(jq -r '.iid' <<<"$view")
  cr_ref="!$number"
  url=$(jq -r '.web_url' <<<"$view")
  title=$(jq -r '.title' <<<"$view")
  state=$(jq -r '.state' <<<"$view")
  draft=$(jq -r '.draft // .work_in_progress // false' <<<"$view")
  head_sha=$(jq -r '.sha' <<<"$view")
  source_branch=$(jq -r '.source_branch' <<<"$view")
  target_branch=$(jq -r '.target_branch' <<<"$view")
  commits_json=$(glab api --paginate "projects/:fullpath/merge_requests/$number/commits?per_page=100" 2>&1) \
    || die "could not read the CR's commits" "$commits_json"
  commits=$(jq -s 'add | length' <<<"$commits_json")
fi
[[ "$state" == opened ]] && state=open

emit CR_REF "$cr_ref"
emit CR_NUMBER "$number"
emit CR_URL "$url"
emit CR_TITLE "$title"
emit CR_STATE "$state"
emit CR_HEAD_SHA "$head_sha"
emit CR_SOURCE_BRANCH "$source_branch"
emit CR_TARGET_BRANCH "$target_branch"
emit CR_COMMITS "$commits"

if [[ "$state" != open ]]; then
  emit GATE_BLOCKING state
  exit 0
fi

# --- The checkout -----------------------------------------------------------

# Merging a head this checkout hasn't seen lands code nobody reviewed here.
local_head=$(git rev-parse HEAD)
if [[ -n "$(git status --porcelain)" ]]; then
  local_state=dirty
elif [[ "$local_head" != "$head_sha" ]]; then
  local_state=head-mismatch
else
  local_state=ok
fi
emit LOCAL_HEAD_SHA "$local_head"
emit LOCAL_STATE "$local_state"

# block <gate> — the first gate that isn't passing ends the read. The ones after
# it wait on this one being cleared, and are read fresh on the next run.
block() { emit GATE_BLOCKING "$1"; exit 0; }

[[ "$local_state" == ok ]] || block local

# --- Draft ------------------------------------------------------------------

if [[ "$draft" == true ]]; then
  emit GATE_DRAFT draft
  block draft
fi
emit GATE_DRAFT clear

# --- Mergeable --------------------------------------------------------------

mergeable_state() {
  if [[ "$forge" == github ]]; then
    # BLOCKED and UNSTABLE are the review and check gates, read on their own below.
    case "$(jq -r '.mergeable' <<<"$view"):$(jq -r '.mergeStateStatus' <<<"$view")" in
      CONFLICTING:*|*:DIRTY) echo conflicts ;;
      *:BEHIND)              echo behind ;;
      UNKNOWN:*|*:UNKNOWN)   echo unknown ;;
      *)                     echo ok ;;
    esac
  else
    case "$(jq -r '.detailed_merge_status // ""' <<<"$view")" in
      conflict)    echo conflicts ;;
      need_rebase) echo behind ;;
      checking|unchecked|preparing|approvals_syncing) echo unknown ;;
      # The gate-not-met states, which the approval, pipeline, thread, and draft
      # reads report on their own.
      mergeable|not_approved|requested_changes|ci_still_running|ci_must_pass|discussions_not_resolved|draft_status)
        echo ok ;;
      "")
        case "$(jq -r '.merge_status // ""' <<<"$view")" in
          can_be_merged)    echo ok ;;
          cannot_be_merged) echo conflicts ;;
          *)                echo unknown ;;
        esac ;;
      *) echo blocked ;;
    esac
  fi
}

mergeable_detail() {
  if [[ "$forge" == github ]]; then
    jq -r '"\(.mergeable | ascii_downcase), \(.mergeStateStatus | ascii_downcase)"' <<<"$view"
  else
    jq -r '.detailed_merge_status // .merge_status' <<<"$view"
  fi
}

reread_view() {
  if [[ "$forge" == github ]]; then
    view=$(gh pr view "$number" --json "$fields" 2>&1) || die "could not re-read the CR" "$view"
  else
    view=$(glab mr view "$number" --output json 2>&1) || die "could not re-read the CR" "$view"
  fi
}

mergeable=$(mergeable_state)
tries=1
while [[ "$mergeable" == unknown && "$tries" -lt "$MERGEABLE_RETRIES" ]]; do
  sleep "$MERGEABLE_DELAY"
  reread_view
  mergeable=$(mergeable_state)
  tries=$((tries + 1))
done
emit GATE_MERGEABLE "$mergeable"
emit GATE_MERGEABLE_DETAIL "$(mergeable_detail)"
[[ "$mergeable" == ok ]] || block mergeable

# --- Pipeline ---------------------------------------------------------------

# The same helper /anchor:pipeline reads, on the one run for the CR head. Whether
# every required check passed is the forge's own merge check, read above.
pipeline=$(bash "$here/pipeline-status.sh" --single-run --sha "$head_sha")
pipe_state=$(sed -n 's/^PIPELINE_STATE=//p' <<<"$pipeline")
pipe_id=$(sed -n 's/^PIPELINE_ID=//p' <<<"$pipeline")
pipe_runs=$(sed -n 's/^PIPELINE_RUNS=//p' <<<"$pipeline")
pipe_failed=$(sed -n 's/^PIPELINE_FAILED_JOBS=//p' <<<"$pipeline")
if [[ -n "$pipe_runs" ]]; then
  # PIPELINE_RUNS lists every run for the commit; the gate is about the one
  # the verdict came from.
  pipe_detail=$(jq -r --arg id "$pipe_id" --arg sha "${head_sha:0:7}" \
    '[.[] | select(.id == $id) | .jobs[]]
     | "\(map(select(.state == "success")) | length)/\(length) jobs on \($sha)"' <<<"$pipe_runs")
else
  pipe_detail="none for this commit"
fi
# GitHub reports failing required checks only as BLOCKED, which the mergeable
# read leaves to this gate, and the run above may be a different workflow. A
# BLOCKED PR with a failing check is a pipeline block, raised here rather than
# as the forge's refusal after the merge was confirmed.
if [[ "$forge" == github && "$pipe_state" != failed \
      && "$(jq -r '.mergeStateStatus' <<<"$view")" == BLOCKED ]]; then
  failing=$(jq -c '[.statusCheckRollup[]?
    | select((.conclusion // .state // "") as $c
             | ["FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","ERROR"] | index($c))
    | {name: (.name // .context), url: (.detailsUrl // .targetUrl // "")}]' <<<"$view")
  if [[ "$(jq 'length' <<<"$failing")" -gt 0 ]]; then
    pipe_state=failed
    pipe_detail="$(jq -r 'length' <<<"$failing") failing check(s) block the merge"
    pipe_failed="$failing"
  fi
fi
emit GATE_PIPELINE "$pipe_state"
emit GATE_PIPELINE_DETAIL "$pipe_detail"
sed -n -e '/^PIPELINE_URL=/p' -e '/^PIPELINE_ERROR=/p' <<<"$pipeline"
[[ -z "$pipe_failed" ]] || echo "PIPELINE_FAILED_JOBS=$pipe_failed"
case "$pipe_state" in
  # skipped: every workflow for the commit was filtered out (paths, branches),
  # which is the same as having none.
  success|none|absent|skipped) ;;
  *) block pipeline ;;
esac

# --- Approvals --------------------------------------------------------------

if [[ "$forge" == github ]]; then
  case "$(jq -r '.reviewDecision // ""' <<<"$view")" in
    APPROVED)          approvals=met;               approvals_detail="approved" ;;
    CHANGES_REQUESTED) approvals=changes-requested; approvals_detail="changes requested" ;;
    REVIEW_REQUIRED)   approvals=missing;           approvals_detail="review required" ;;
    *)                 approvals=none;              approvals_detail="no approval rules" ;;
  esac
else
  appr=$(glab api "projects/:fullpath/merge_requests/$number/approvals" 2>&1) \
    || die "could not read the CR's approvals" "$appr"
  required=$(jq -r '.approvals_required // 0' <<<"$appr")
  left=$(jq -r '.approvals_left // 0' <<<"$appr")
  by=$(jq -r '[.approved_by[]?.user.username | "@\(.)"] | join(", ")' <<<"$appr")
  approvals_detail="$required required, $left left${by:+; approved by $by}"
  if [[ "$(jq -r '.detailed_merge_status // ""' <<<"$view")" == requested_changes ]]; then
    approvals=changes-requested
  elif [[ "$left" -gt 0 ]]; then
    approvals=missing
  elif [[ "$required" -eq 0 && -z "$by" ]]; then
    approvals=none
    approvals_detail="no approval rules"
  else
    approvals=met
  fi
fi
emit GATE_APPROVALS "$approvals"
emit GATE_APPROVALS_DETAIL "$approvals_detail"
case "$approvals" in
  met|none) ;;
  *) block approvals ;;
esac

# --- Review threads ---------------------------------------------------------

if [[ "$forge" == github ]]; then
  # {owner} and {repo} are filled in by gh from the checkout's remote.
  # shellcheck disable=SC2016  # $owner etc. are GraphQL variables, not shell ones
  raw=$(gh api graphql -F owner='{owner}' -F repo='{repo}' -F pr="$number" -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){pullRequest(number:$pr){
        reviewThreads(first:100){nodes{isResolved path line
          comments(first:1){nodes{author{login __typename} body}}}}}}}' 2>&1) \
    || die "could not read the CR's review threads" "$raw"
  threads=$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved | not)
      | .comments.nodes[0] as $c
      | select($c.author.__typename != "Bot")
      | {path, line, author: $c.author.login, body: ($c.body | .[0:120])}]' <<<"$raw")
else
  raw=$(glab api --paginate "projects/:fullpath/merge_requests/$number/discussions?per_page=100" 2>&1) \
    || die "could not read the CR's review threads" "$raw"
  threads=$(jq -cs '[.[][]
      | select(.notes[0].system | not)
      | select([.notes[] | .resolvable and (.resolved | not)] | any)
      | .notes[0] as $n
      | {path: $n.position.new_path, line: $n.position.new_line,
         author: $n.author.username, body: ($n.body | .[0:120])}]' <<<"$raw")
fi
open=$(jq -r 'length' <<<"$threads")
if [[ "$open" -gt 0 ]]; then
  emit GATE_THREADS open
  emit GATE_THREADS_DETAIL "$open unresolved"
else
  emit GATE_THREADS resolved
  emit GATE_THREADS_DETAIL "none unresolved"
fi
emit THREADS "$threads"

# --- Merge method -----------------------------------------------------------

# A merge commit that keeps every commit on the branch, unless the forge is
# configured otherwise. The shape of the branch's history never moves it.
method=merge
squash=0
setting=""
if [[ "$forge" == github ]]; then
  allowed=$(gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed 2>&1) \
    || die "could not read the repo's merge settings" "$allowed"
  if [[ "$(jq -r '.mergeCommitAllowed' <<<"$allowed")" != true ]]; then
    if [[ "$(jq -r '.rebaseMergeAllowed' <<<"$allowed")" == true ]]; then
      method=rebase
      setting="the repo disallows merge commits"
    else
      method=squash
      squash=1
      setting="the repo allows only squash merges"
    fi
  fi
else
  project=$(glab api "projects/:fullpath" 2>&1) || die "could not read the project's merge settings" "$project"
  method=$(jq -r '.merge_method // "merge"' <<<"$project")
  case "$method" in
    ff)           setting="the project's merge method is fast-forward" ;;
    rebase_merge) setting="the project's merge method is semi-linear" ;;
  esac
  case "$(jq -r '.squash_option // "default_off"' <<<"$project")" in
    always) squash=1; setting="${setting:+$setting, and }the project requires squash" ;;
    never)  ;;
    *)
      if [[ "$(jq -r '.squash // false' <<<"$view")" == true ]]; then
        squash=1
        setting="${setting:+$setting, and }the MR is set to squash"
      fi ;;
  esac
fi

case "$method:$squash" in
  merge:0)        label="merge commit (preserves $commits commit$([[ "$commits" == 1 ]] || echo s))" ;;
  rebase:0)       label="rebase, no merge commit" ;;
  ff:0)           label="fast-forward, no merge commit" ;;
  rebase_merge:0) label="semi-linear merge commit" ;;
  ff:1)           label="squash, fast-forward" ;;
  *:1)            label="squash into one commit" ;;
esac

emit MERGE_METHOD "$method"
emit MERGE_SQUASH "$squash"
emit MERGE_METHOD_LABEL "$label"
emit MERGE_METHOD_SETTING "$setting"

if [[ "$open" -gt 0 ]]; then
  emit GATE_BLOCKING threads
else
  emit GATE_BLOCKING ""
fi
