#!/usr/bin/env bash
# Read and reshape a stack of change requests, for /anchor:stack.
#
# Why a script (not skill prose): which CR sits on which, what each one's checks
# and review say, whether a CR's target disagrees with the branch it was cut
# from, and the forge call that retargets one are facts, the same on every run.
# Each forge spells them differently. What the skill keeps is choosing a branch
# name, asking, and walking the stack with /anchor:review and /anchor:rebase.
#
# Subcommands:
#   show       read only. Every open CR, arranged as trees by target, with each
#              one's state, rendered as lines the skill prints as they stand.
#   new        cut a branch for the next CR at HEAD, on top of the current one.
#   retarget   point the current branch's CR at another base. Rebasing onto that
#              base is scripts/rebase.sh, which follows the CR's target.
#   link       GitHub only: make the stack holding the current branch one of
#              GitHub's stacks (`gh stack link`, from the github/gh-stack
#              extension). Chained targets alone don't make one; a GitHub stack
#              is its own object, with its own view and number on each PR.
#
# A CR's parent is the open CR whose branch it targets. A CR that targets the
# default branch while its commits sit on another open CR's branch (a stacked CR
# opened, or retargeted, against the default branch) is drawn under that CR and
# flagged, since its diff repeats the commits below it. Only the CRs `show`
# displays are checked for that, which keeps the merge-base walk to the stacks
# being looked at.
#
# Output lines (KEY=value, stdout). show:
#   FORGE, BRANCH, DEFAULT_BRANCH, VIEWER
#   FETCH_ERROR=<message>     the fetch failed, so no CR's base was checked
#   STACK_TREES=<n>           trees shown
#   TREE=<line>               the rendered trees, in order; an empty TREE=
#                             separates two
#   STACK_CR=<depth> <ref> <branch> <target> <draft|ready> <checks> <review> <merge> <author> <flag> <title>
#                             one per CR shown, in tree order (bottom to top)
#       checks  passed|failed|running|manual|none
#       review  approved|changes-requested|required|none
#       merge   now|waits|blocked|conflicts|behind|unknown   (now: a root CR
#               that can land as it stands; waits: one with a CR under it)
#       flag    -|stacked-on:<branch>|base-not-open
#   STACK_ORDER=<ref,ref,...>  the tree holding the current branch, bottom to top
#   NATIVE_STACK=<linked|unlinked|no-gh-stack>
#                             GitHub only, for a STACK_ORDER of two or more CRs
#                             in one line with no flag: whether GitHub holds
#                             them as one stack (no-gh-stack: it doesn't, and the
#                             gh-stack extension that links them is missing)
#
# new:
#   NEW_BRANCH, BASE_BRANCH, STACKED=<0|1>   (0: cut from the default branch)
#   BASE_CR_REF, BASE_CR_URL   the base branch's open CR; empty when none
#   BASE_PUSHED=<0|1>          origin holds the base branch
#
# retarget:
#   CR_REF, CR_URL, PREVIOUS_TARGET, NEW_TARGET
#   RETARGET=<done|unchanged|no-cr>
#   CONFIRM_OTHERS=<cr>:<author>   (exit 66; nothing changed)
#
# link:
#   LINK_ORDER=<ref,ref,...>   the CRs linked, bottom to top
#   LINK=<done|unchanged>      unchanged: GitHub already holds them as one stack
#   NATIVE_STACK_NUMBER=<n>    the stack's number on GitHub
#   CONFIRM_OTHERS=<cr>:<author>,...   (exit 66; nothing changed)
#
# Errors: STACK_ERROR=<message>, plus STACK_AUTH=1 when the forge refused the
# credentials.
#
# Exit codes:
#   0   done
#   1   STACK_ERROR
#   64  usage error
#   66  needs the user's yes (CONFIRM_OTHERS); re-run with --allow-others
#
# Usage:
#   stack.sh show [--all] [--repo <path>]
#   stack.sh new <branch> [--repo <path>]
#   stack.sh retarget --onto <branch|#n|!n|n|cr-url> [--allow-others] [--repo <path>]
#   stack.sh link [--allow-others] [--repo <path>]

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stack.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"

usage() {
  echo "usage: stack.sh show [--all] [--repo <path>] | new <branch> [--repo <path>] | retarget --onto <base> [--allow-others] [--repo <path>] | link [--allow-others] [--repo <path>]" >&2
  exit 64
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift

all=0
allow_others=0
onto=""
new_branch=""
CTX_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)          all=1; shift ;;
    --allow-others) allow_others=1; shift ;;
    --onto)         onto="${2:-}"; [[ -n "$onto" ]] || usage; shift 2 ;;
    --repo)         CTX_REPO="${2:-}"; [[ -n "$CTX_REPO" ]] || usage; shift 2 ;;
    -*)             usage ;;
    *)              [[ "$cmd" == new && -z "$new_branch" ]] || usage; new_branch="$1"; shift ;;
  esac
done
case "$cmd" in
  show)     [[ -z "$onto$new_branch" && $allow_others -eq 0 ]] || usage ;;
  new)      [[ -n "$new_branch" && -z "$onto" && $all -eq 0 && $allow_others -eq 0 ]] || usage ;;
  retarget) [[ -n "$onto" && $all -eq 0 ]] || usage ;;
  link)     [[ -z "$onto$new_branch" && $all -eq 0 ]] || usage ;;
  *)        usage ;;
esac

ctx_resolve_repo

die() {
  echo "STACK_ERROR=$1"
  [[ "${2:-}" == auth ]] && echo "STACK_AUTH=1"
  exit 1
}

# A forge CLI failure, classified: an authentication failure is marked so the
# skill asks for fresh credentials rather than retrying.
forge_fail() {
  local what=$1 out=$2
  if grep -qiE '401|403|unauthori[sz]ed|authentication|not logged|auth login' <<<"$out"; then
    die "$what: $(head -1 <<<"$out")" auth
  fi
  die "$what: $(head -1 <<<"$out")"
}

forge=$(anchor_forge_of_origin)
[[ "$forge" != none ]] || die "origin is neither GitHub nor GitLab"
default_branch=$(anchor_default_branch) || die "origin has no default branch here; fetch it first"
branch=$(git symbolic-ref --quiet --short HEAD) || die "HEAD is detached; check out a branch"

mark() { [[ "$forge" == gitlab ]] && echo '!' || echo '#'; }

# The open CRs, normalized to one JSON array. The per-CR checks and review for
# GitLab come later, for the CRs shown, since its list carries neither.
open_crs_json() {
  local out
  case "$forge" in
    github)
      out=$(gh pr list --state open --limit 100 --json \
        number,title,url,headRefName,headRefOid,baseRefName,isDraft,author,reviewDecision,mergeStateStatus,statusCheckRollup 2>&1) \
        || forge_fail "gh pr list failed" "$out"
      jq -c '
        def checks:
          (.statusCheckRollup // []) as $c
          | if ($c | length) == 0 then "none"
            elif any($c[]; ((.conclusion // "") | test("FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE"))
                          or ((.state // "") | test("FAILURE|ERROR"))) then "failed"
            elif any($c[]; ((.status // "") | test("IN_PROGRESS|QUEUED|PENDING|WAITING|REQUESTED"))
                          or ((.state // "") | test("PENDING|EXPECTED"))) then "running"
            else "passed" end;
        [ .[] | {
            num: .number, title: .title, url: .url, head: .headRefName, sha: .headRefOid,
            target: .baseRefName, draft: (.isDraft // false), author: (.author.login // ""),
            checks: checks,
            review: ({"APPROVED": "approved", "CHANGES_REQUESTED": "changes-requested",
                      "REVIEW_REQUIRED": "required"}[.reviewDecision // ""] // "none"),
            merge: ({"CLEAN": "ok", "HAS_HOOKS": "ok", "UNSTABLE": "ok", "DIRTY": "conflicts",
                     "BEHIND": "behind", "BLOCKED": "blocked", "DRAFT": "ok"}[.mergeStateStatus // ""] // "unknown")
          } ]' <<<"$out" ;;
    gitlab)
      out=$(glab mr list --output json --per-page 100 2>&1) || forge_fail "glab mr list failed" "$out"
      jq -c '[ .[] | {
            num: .iid, title: .title, url: .web_url, head: .source_branch, sha: .sha,
            target: .target_branch, draft: (.draft // false), author: (.author.username // ""),
            checks: "none", review: "none",
            merge: ({"mergeable": "ok", "conflict": "conflicts", "need_rebase": "behind",
                     "checking": "unknown", "unchecked": "unknown", "preparing": "unknown"}[.detailed_merge_status // ""] // "blocked")
          } ]' <<<"$out" ;;
  esac
}

viewer() {
  local out
  out=$(anchor_forge_self "$forge") || forge_fail "could not read the signed-in user" "$out"
  printf '%s\n' "$out"
}

# --- show -------------------------------------------------------------------------

# Parent links and flags, from targets alone plus each CR's stacked-on branch.
# shellcheck disable=SC2016  # jq variables, expanded by jq
TREE_JQ='
def parented($default):
  . as $all
  | map(. as $c
      | ($all | map(.head)) as $heads
      | if ($c.stackedOn // "") != "" then $c + {parent: $c.stackedOn, flag: ("stacked-on:" + $c.stackedOn)}
        elif $c.target == $default then $c + {parent: null, flag: "-"}
        elif ($heads | index($c.target)) != null then $c + {parent: $c.target, flag: "-"}
        else $c + {parent: null, flag: "base-not-open"} end);

def walk_tree($all; $c; $d):
  if $d > 50 then [] else
    [$c + {depth: $d}]
    + ([$all[] | select(.parent == $c.head)] | sort_by(.num)
       | map(walk_tree($all; .; $d + 1)) | add // [])
  end;

def trees:
  . as $all | [$all[] | select(.parent == null)] | sort_by(.num) | map(walk_tree($all; .; 0));

def keep($branch; $viewer; $showall):
  map(select($showall or any(.[]; .author == $viewer or .head == $branch)))
  | sort_by(if any(.[]; .head == $branch) then 0 else 1 end);
'

stacked_on() {
  local crs=$1 picks_for=$2 tsv head sha pick
  tsv=$(jq -r '.[] | [.head, .sha, (.num | tostring), .url, .target] | @tsv' <<<"$crs")
  while IFS=$'\t' read -r head sha; do
    [[ -n "$head" ]] || continue
    git cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    pick=$(anchor_stack_pick "$head" "$default_branch" "$sha" <<<"$tsv")
    [[ -z "$pick" ]] || printf '%s\t%s\n' "$head" "${pick%%$'\t'*}"
  done <<<"$picks_for"
}

gitlab_details() {
  local iid out pipe approvals
  for iid in "$@"; do
    out=$(glab api "projects/:fullpath/merge_requests/$iid" 2>&1) || forge_fail "glab api merge_requests/$iid failed" "$out"
    pipe=$(jq -r '.head_pipeline.status // ""' <<<"$out")
    approvals=$(glab api "projects/:fullpath/merge_requests/$iid/approvals" 2>&1) \
      || forge_fail "glab api merge_requests/$iid/approvals failed" "$approvals"
    jq -cn --argjson n "$iid" --arg p "$pipe" --argjson a "$approvals" '{
      num: $n,
      checks: (if $p == "" then "none"
               elif $p == "success" then "passed"
               elif ($p | test("^(failed|canceled)$")) then "failed"
               elif $p == "manual" then "manual"
               elif $p == "skipped" then "none"
               else "running" end),
      review: (if ($a.approved // false) and (($a.approvals_left // 0) == 0) and (($a.approved_by // []) | length) > 0 then "approved"
               elif ($a.approvals_left // 0) > 0 then "required"
               else "none" end)
    }'
  done | jq -sc 'map({key: (.num | tostring), value: .}) | from_entries'
}

# Fetch, then mark each default-targeting CR among the stacks `keep` shows with
# the open CR branch its commits sit on. Reads and sets the caller's `crs`,
# `who`, and `fetch_err`.
annotate_stacked_on() {
  local showall=$1 shown picks pairs=""
  if ! fetch_err=$(git fetch --quiet origin 2>&1); then
    fetch_err=$(head -1 <<<"$fetch_err")
    [[ -n "$fetch_err" ]] || fetch_err="git fetch origin failed"
  else
    fetch_err=""
  fi

  shown=$(jq -c --arg b "$branch" --arg v "$who" --argjson sa "$showall" --arg d "$default_branch" \
    "$TREE_JQ"' map(. + {stackedOn: ""}) | parented($d) | trees | keep($b; $v; $sa == 1) | add // [] | map(.head)' <<<"$crs")
  if [[ -z "$fetch_err" ]]; then
    picks=$(jq -r --arg d "$default_branch" --argjson shown "$shown" \
      '.[] | select(.target == $d and (.head as $h | $shown | index($h)) != null) | [.head, .sha] | @tsv' <<<"$crs")
    pairs=$(stacked_on "$crs" "$picks")
  fi
  crs=$(jq -c --arg pairs "$pairs" '
    ($pairs | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $on
    | map(. + {stackedOn: ($on[.head] // "")})' <<<"$crs")
}

# The tree holding the current branch, as GitHub's stacks see it: its CRs bottom
# to top, whether it is one line (a GitHub stack can't fork), the first CR whose
# target disagrees with where it sits, and the CRs someone else opened.
current_chain() {
  jq -c --arg b "$branch" --arg v "$who" --arg d "$default_branch" --arg m "$(mark)" "$TREE_JQ"'
    parented($d) | trees | map(select(any(.[]; .head == $b))) | (.[0] // [])
    | { nums: map(.num),
        refs: map($m + (.num | tostring)),
        linear: (map(.depth) == [range(length)]),
        stray: (map(select(.flag != "-")) | .[0] // null | if . then $m + (.num | tostring) else null end),
        others: map(select(.author != $v) | $m + (.num | tostring) + ":" + .author) }' <<<"$crs"
}

# Sets the caller's `native` to linked:<stack number>, unlinked, or unsupported
# (the host's API has no stacks), for the PR numbers given.
native_state() {
  local q="" n out
  for n in "$@"; do q+=" p$n: pullRequest(number: $n) { stack { number } }"; done
  # shellcheck disable=SC2016  # GraphQL variables, not shell ones
  if ! out=$(gh api graphql -F owner='{owner}' -F name='{repo}' \
      -f query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {'"$q"' } }' 2>&1); then
    if grep -q "doesn't exist on type" <<<"$out"; then
      native=unsupported
      return 0
    fi
    forge_fail "gh api graphql (pull request stacks) failed" "$out"
  fi
  native=$(jq -r '[.data.repository[] | .stack.number]
    | if length > 0 and all(. != null) and (unique | length) == 1 then "linked:\(.[0])" else "unlinked" end' <<<"$out")
}

has_gh_stack() { gh stack --version >/dev/null 2>&1; }

cmd_show() {
  local crs who fetch_err="" details iids chain native=""
  crs=$(open_crs_json)
  who=$(viewer)
  annotate_stacked_on "$all"

  if [[ "$forge" == gitlab ]]; then
    iids=$(jq -r --arg b "$branch" --arg v "$who" --argjson sa "$all" --arg d "$default_branch" \
      "$TREE_JQ"' parented($d) | trees | keep($b; $v; $sa == 1) | add // [] | .[].num' <<<"$crs")
    # shellcheck disable=SC2086
    details=$(gitlab_details $iids)
    [[ -n "$details" ]] || details='{}'
    crs=$(jq -c --argjson det "$details" \
      'map(. + ($det[(.num | tostring)] // {} | {checks, review} | with_entries(select(.value != null))))' <<<"$crs")
  fi

  printf 'FORGE=%s\nBRANCH=%s\nDEFAULT_BRANCH=%s\nVIEWER=%s\n' "$forge" "$branch" "$default_branch" "$who"
  [[ -z "$fetch_err" ]] || printf 'FETCH_ERROR=%s\n' "$fetch_err"

  jq -r --arg b "$branch" --arg v "$who" --argjson sa "$all" --arg d "$default_branch" --arg m "$(mark)" \
    "$TREE_JQ"'
    def ref: $m + (.num | tostring);
    def short: if (.title | length) > 60 then .title[0:59] + "…" else .title end;
    def mergeable:
      .depth == 0 and .flag == "-" and (.draft | not) and (.checks == "passed" or .checks == "none")
      and (.review == "approved" or .review == "none") and .merge == "ok";
    def merge_state:
      if .depth > 0 then "waits"
      elif mergeable then "now"
      elif .merge == "ok" then "blocked"
      else .merge end;
    def line($all):
      . as $c
      | ($all | map(select(.head == $c.parent)) | .[0]) as $p
      | (if .depth == 0 then "" else ("  " * (.depth - 1)) + "└ " end)
        + ref + " " + short
        + (if .draft then " (draft)" else "" end)
        + (if .checks == "failed" then " · checks failing"
           elif .checks == "running" then " · checks running"
           elif .checks == "manual" then " · checks waiting on a manual job" else "" end)
        + (if .review == "changes-requested" then " · changes requested" else "" end)
        + (if .depth == 0 and .merge == "conflicts" then " · conflicts"
           elif .depth == 0 and .merge == "behind" then " · behind its base" else "" end)
        + (if (.flag | startswith("stacked-on:")) then " ⚠ targets " + .target + ", stacked on " + ($p | ref)
           elif .flag == "base-not-open" then " ⚠ base " + .target + " has no open CR" else "" end)
        + ([ (if merge_state == "now" then "mergeable now" else empty end),
             (if .head == $b then "current branch" else empty end) ]
           | if length > 0 then " ← " + join(", ") else "" end);

    parented($d) as $all
    | ($all | trees | keep($b; $v; $sa == 1)) as $trees
    | "STACK_TREES=\($trees | length)",
      ($trees | to_entries[] | (if .key > 0 then "TREE=" else empty end), (.value[] | "TREE=" + line($all))),
      ($trees[][] | "STACK_CR=\(.depth) \(ref) \(.head) \(.target) \(if .draft then "draft" else "ready" end) \(.checks) \(.review) \(merge_state) \(.author) \(.flag) \(.title)"),
      "STACK_ORDER=" + ([$trees[] | select(any(.[]; .head == $b)) | .[] | ref] | join(","))
  ' <<<"$crs"

  [[ "$forge" == github ]] || return 0
  chain=$(current_chain)
  jq -e '(.nums | length) > 1 and .linear and .stray == null' <<<"$chain" >/dev/null || return 0
  # shellcheck disable=SC2046  # PR numbers, one word each
  native_state $(jq -r '.nums[]' <<<"$chain")
  case "$native" in
    linked:*) echo "NATIVE_STACK=linked" ;;
    unlinked) if has_gh_stack; then echo "NATIVE_STACK=unlinked"; else echo "NATIVE_STACK=no-gh-stack"; fi ;;
  esac
}

# --- new --------------------------------------------------------------------------

cmd_new() {
  local base=$branch cr_ref="" cr_url="" pushed=0 stacked=1 json
  git check-ref-format --branch "$new_branch" >/dev/null 2>&1 || die "'$new_branch' is not a valid branch name"
  git rev-parse --verify --quiet "refs/heads/$new_branch" >/dev/null && die "a branch named '$new_branch' exists here"
  git fetch --quiet origin 2>/dev/null || true
  git rev-parse --verify --quiet "refs/remotes/origin/$new_branch" >/dev/null && die "origin already has a branch named '$new_branch'"
  [[ "$base" == "$default_branch" ]] && stacked=0
  git rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null && pushed=1

  if [[ $stacked -eq 1 ]]; then
    case "$forge" in
      github)
        if json=$(gh pr view "$base" --json url,number,state 2>/dev/null) \
            && [[ "$(jq -r '.state // empty' <<<"$json")" == OPEN ]]; then
          cr_url=$(jq -r '.url' <<<"$json"); cr_ref="#$(jq -r '.number' <<<"$json")"
        fi ;;
      gitlab)
        if json=$(glab mr view "$base" --output json 2>/dev/null) \
            && [[ "$(jq -r '.state // empty' <<<"$json")" == opened ]]; then
          cr_url=$(jq -r '.web_url' <<<"$json"); cr_ref="!$(jq -r '.iid' <<<"$json")"
        fi ;;
    esac
  fi

  git switch --quiet -c "$new_branch" || die "git switch -c $new_branch failed"
  printf 'NEW_BRANCH=%s\nBASE_BRANCH=%s\nSTACKED=%s\nBASE_CR_REF=%s\nBASE_CR_URL=%s\nBASE_PUSHED=%s\n' \
    "$new_branch" "$base" "$stacked" "$cr_ref" "$cr_url" "$pushed"
}

# --- retarget ---------------------------------------------------------------------

cmd_retarget() {
  local crs mine num author target url to n chain hop who out
  [[ "$branch" != "$default_branch" ]] || die "HEAD is the default branch, which has no CR to retarget"
  crs=$(open_crs_json)

  mine=$(jq -c --arg b "$branch" '[.[] | select(.head == $b)][0] // empty' <<<"$crs")
  if [[ -z "$mine" ]]; then
    printf 'RETARGET=no-cr\n'
    return 0
  fi
  num=$(jq -r '.num' <<<"$mine"); url=$(jq -r '.url' <<<"$mine")
  author=$(jq -r '.author' <<<"$mine"); target=$(jq -r '.target' <<<"$mine")

  to="${onto#origin/}"
  case "$to" in
    \#*|\!*) n="${to#?}" ;;
    *[0-9]) [[ "$to" =~ /(pull|merge_requests)/([0-9]+)$ ]] && n="${BASH_REMATCH[2]}" || n="" ;;
    *) n="" ;;
  esac
  [[ -z "$n" && "$to" =~ ^[0-9]+$ ]] && n="$to"
  if [[ -n "$n" ]]; then
    to=$(jq -r --argjson n "$n" '[.[] | select(.num == $n)][0].head // empty' <<<"$crs")
    [[ -n "$to" ]] || die "$(mark)$n is not an open CR here"
  fi
  [[ "$to" != "$branch" ]] || die "a CR can't target its own branch"
  git fetch --quiet origin "$to" 2>/dev/null || true
  git rev-parse --verify --quiet "refs/remotes/origin/$to" >/dev/null || die "origin has no branch '$to'"

  # Walk down from the new base; reaching this branch would make a cycle.
  chain=$to
  for hop in $(seq 1 50); do
    [[ "$chain" != "$default_branch" ]] || break
    [[ "$chain" != "$branch" ]] || die "'$to' is stacked on '$branch', so targeting it would make a cycle"
    chain=$(jq -r --arg h "$chain" '[.[] | select(.head == $h)][0].target // empty' <<<"$crs")
    [[ -n "$chain" ]] || break
    : "$hop"
  done

  printf 'CR_REF=%s%s\nCR_URL=%s\nPREVIOUS_TARGET=%s\nNEW_TARGET=%s\n' "$(mark)" "$num" "$url" "$target" "$to"
  if [[ "$target" == "$to" ]]; then
    printf 'RETARGET=unchanged\n'
    return 0
  fi

  who=$(viewer)
  if [[ "$author" != "$who" && $allow_others -eq 0 ]]; then
    printf 'CONFIRM_OTHERS=%s%s:%s\n' "$(mark)" "$num" "$author"
    exit 66
  fi

  case "$forge" in
    github) out=$(gh pr edit "$num" --base "$to" 2>&1) || forge_fail "gh pr edit --base failed" "$out" ;;
    gitlab) out=$(glab mr update "$num" --target-branch "$to" 2>&1) || forge_fail "glab mr update --target-branch failed" "$out" ;;
  esac
  printf 'RETARGET=done\n'
}

# --- link -------------------------------------------------------------------------

cmd_link() {
  local crs who fetch_err="" chain stray others native="" out
  [[ "$forge" == github ]] || die "a stack of linked CRs is a GitHub feature; on GitLab the chained targets are the stack"
  crs=$(open_crs_json)
  who=$(viewer)
  annotate_stacked_on 0
  [[ -z "$fetch_err" ]] || die "git fetch origin failed, so no CR's base could be checked: $fetch_err"

  chain=$(current_chain)
  jq -e '(.nums | length) > 0' <<<"$chain" >/dev/null || die "no open CR is on '$branch' or in a stack holding it"
  jq -e '(.nums | length) > 1' <<<"$chain" >/dev/null || die "the stack holding '$branch' has one CR, so there is nothing to link"
  jq -e '.linear' <<<"$chain" >/dev/null || die "the stack holding '$branch' forks, and a GitHub stack is one line of CRs"
  stray=$(jq -r '.stray // empty' <<<"$chain")
  [[ -z "$stray" ]] || die "$stray targets a branch other than the one it sits on; move it with /anchor:stack on first"

  printf 'LINK_ORDER=%s\n' "$(jq -r '.refs | join(",")' <<<"$chain")"
  # shellcheck disable=SC2046  # PR numbers, one word each
  native_state $(jq -r '.nums[]' <<<"$chain")
  [[ "$native" != unsupported ]] || die "this GitHub host's API has no pull request stacks"
  if [[ "$native" == linked:* ]]; then
    printf 'LINK=unchanged\nNATIVE_STACK_NUMBER=%s\n' "${native#linked:}"
    return 0
  fi

  others=$(jq -r '.others | join(",")' <<<"$chain")
  if [[ -n "$others" && $allow_others -eq 0 ]]; then
    printf 'CONFIRM_OTHERS=%s\n' "$others"
    exit 66
  fi
  has_gh_stack || die "linking needs the gh-stack extension: gh extension install github/gh-stack"

  # shellcheck disable=SC2046  # PR numbers, one word each
  out=$(gh stack link --base "$default_branch" $(jq -r '.nums[]' <<<"$chain") 2>&1) \
    || forge_fail "gh stack link failed" "$out"
  # shellcheck disable=SC2046
  native_state $(jq -r '.nums[]' <<<"$chain")
  [[ "$native" == linked:* ]] || die "gh stack link reported success, but GitHub doesn't hold the CRs as one stack"
  printf 'LINK=done\nNATIVE_STACK_NUMBER=%s\n' "${native#linked:}"
}

case "$cmd" in
  show)     cmd_show ;;
  new)      cmd_new ;;
  retarget) cmd_retarget ;;
  link)     cmd_link ;;
esac
