#!/usr/bin/env bash
# Clear a change request's draft flag, and announce that it happened.
#
# Three skills reach this moment from different directions — /anchor:ready, where
# the author asks for it outright; the self-review handoff in /anchor:review,
# where the author is done and wants eyes on it; and /anchor:merge's draft gate,
# where they are landing one that never left draft — and a subscriber cannot tell
# those apart, nor should it have to. All call here, so `cr.ready` has one
# emission point and one shape.
#
# Why a script (not skill prose): the flag's per-forge invocation, and reading
# whether it is even set, are deterministic. Whether the change is *ready* is the
# author's call and stays in the skills, which ask before calling this.
#
# The flag is read here rather than taken from the caller. It flips live — a
# reviewer, a CI bot, or the author in another window can mark a CR ready
# between a skill's recon and this call — and a run that announced `cr.ready`
# for a CR that was already ready would report a transition that never happened.
#
# Without --cr, the CR is the checkout's branch's open one. Neither CLI filters
# that lookup by state, so a merged or closed CR on a reused branch name is
# reported as not open rather than adopted. Without --forge, origin names it.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>   which checkout the run operated in
#   FORGE=<github|gitlab>
#   CR_URL=<web url>          the CR, as the forge reports it
#   CR_NUMBER=<n>             PR number / MR iid
#   CR_REF=<repo>#<n> | <repo>!<iid>
#   CR_TITLE=<title>
#   CR_STATE=<open|merged|closed|locked>
#   CR_DRAFT=<true|false>     as read before any change
#   CR_HEAD_SHA=<sha>         the head a reviewer will see
#   CR_SOURCE_BRANCH=<name>
#   LOCAL_STATE=<ok|dirty|head-mismatch|elsewhere>
#                             the checkout against the CR: elsewhere == it is on
#                             another branch, so the other two can't be read
#   CR_BACKUP_PATH=<path>     the CR as it was before the flag came off, saved
#                             through scripts/forge-backup.sh (FORGE-13); a
#                             backup of any CR but CR_URL stops the edit
#   CR_READY=ok               the flag was set on this run
#   ALREADY_READY=1           it was already clear, so nothing was changed
#
# --check reads and reports, and stops before the backup: the keys through
# LOCAL_STATE, with no change to the CR and no announcement.
#
# On a failure it prints READY_ERROR=<message> and exits non-zero rather than
# leaving a caller to read success out of an empty block: 64 a usage error,
# 65 a CR that isn't open (or no open CR on the branch), 70 a forge failure.
#
# Usage:
#   mark-ready.sh                              # the branch's open CR
#   mark-ready.sh --check                      # report it, change nothing
#   mark-ready.sh --forge github --cr 128
#   mark-ready.sh --forge gitlab --cr 42 --repo /path/to/checkout

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"

CTX_REPO=""
forge=""
cr=""
check=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) forge="${2:-}"; shift 2 ;;
    --cr)    cr="${2:-}";    shift 2 ;;
    --check) check=1; shift ;;
    --repo)
      [[ -n "${2:-}" ]] || { echo "READY_ERROR=--repo needs a path" >&2; exit 64; }
      CTX_REPO="$2"; shift 2 ;;
    *) echo "READY_ERROR=unrecognized argument: $1" >&2; exit 64 ;;
  esac
done

case "$forge" in
  github|gitlab|"") ;;
  *)  echo "READY_ERROR=--forge must be github or gitlab, got: $forge" >&2; exit 64 ;;
esac

ctx_resolve_repo

if [[ -z "$forge" ]]; then
  case "$cr" in
    *github.com*) forge=github ;;
    *gitlab*)     forge=gitlab ;;
    *)            forge=$(anchor_forge_of_origin) ;;
  esac
  [[ "$forge" != none ]] \
    || { echo "READY_ERROR=origin is neither GitHub nor GitLab; pass --forge" >&2; exit 64; }
fi

echo "RESOLVED_VIA=$RESOLVED_VIA"
echo "FORGE=$forge"

target=()
[[ -z "$cr" ]] || target=("$cr")
if [[ "$forge" == github ]]; then
  if ! view=$(gh pr view "${target[@]+"${target[@]}"}" \
        --json url,isDraft,number,title,state,headRefOid,headRefName 2>&1); then
    echo "READY_ERROR=could not read CR ${cr:-for this branch}: $view" >&2
    exit 70
  fi
  read_fields='[.url, (.isDraft // false | tostring), (.number // "" | tostring), .title // "",
                (.state // "" | ascii_downcase), .headRefOid // "", .headRefName // ""]'
else
  if ! view=$(glab mr view "${target[@]+"${target[@]}"}" --output json 2>&1); then
    echo "READY_ERROR=could not read CR ${cr:-for this branch}: $view" >&2
    exit 70
  fi
  read_fields='[.web_url, (.draft // false | tostring), (.iid // "" | tostring), .title // "",
                (.state // "" | if . == "opened" then "open" else . end), .sha // "", .source_branch // ""]'
fi
# The trailing line keeps an empty last field, which $(…) would otherwise strip.
if ! fields=$(jq -r "$read_fields | map(. // \"\") | .[]" <<<"$view" 2>&1 && echo end); then
  echo "READY_ERROR=could not parse CR ${cr:-for this branch}: $fields" >&2
  exit 70
fi
cr_url="" draft="" number="" title="" state="" head="" source_branch=""
{ IFS= read -r cr_url; IFS= read -r draft; IFS= read -r number; IFS= read -r title
  IFS= read -r state; IFS= read -r head; IFS= read -r source_branch; } <<<"$fields"
[[ -n "$cr" ]] || cr="$number"

cr_ref=""
[[ -z "$number" ]] || cr_ref=$(anchor_cr_reference "$cr_url" "$number")

local_state=elsewhere
if [[ -n "$source_branch" && "$(git branch --show-current 2>/dev/null)" == "$source_branch" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    local_state=dirty
  elif [[ "$(git rev-parse HEAD)" != "$head" ]]; then
    local_state="head-mismatch"
  else
    local_state=ok
  fi
fi

echo "CR_URL=$cr_url"
echo "CR_NUMBER=$number"
echo "CR_REF=$cr_ref"
echo "CR_TITLE=$title"
echo "CR_STATE=$state"
echo "CR_DRAFT=$draft"
echo "CR_HEAD_SHA=$head"
echo "CR_SOURCE_BRANCH=$source_branch"
echo "LOCAL_STATE=$local_state"

if [[ -n "$state" && "$state" != open ]]; then
  echo "READY_ERROR=${cr_ref:-CR $cr} is $state, not open" >&2
  exit 65
fi

[[ "$check" -eq 0 ]] || exit 0

if [[ "$draft" != "true" ]]; then
  echo "ALREADY_READY=1"
  exit 0
fi

if ! backup=$(anchor_backup_cr "$cr" "$cr_url"); then
  echo "READY_ERROR=could not back up CR $cr before marking it ready: $backup" >&2
  exit 70
fi
echo "CR_BACKUP_PATH=$backup"

# Both forges name the target state rather than toggling it, so this is safe to
# reach twice; the inverse is its own flag.
if [[ "$forge" == github ]]; then
  if ! err=$(gh pr ready "$cr" 2>&1); then
    echo "READY_ERROR=could not mark CR $cr ready: $err" >&2
    exit 70
  fi
else
  if ! err=$(glab mr update "$cr" --ready 2>&1); then
    echo "READY_ERROR=could not mark CR $cr ready: $err" >&2
    exit 70
  fi
fi

echo "CR_READY=ok"

# The announcement follows the mutation, so a subscriber only ever hears about a
# flag that is actually clear.
"$(dirname "${BASH_SOURCE[0]}")/announce.sh" cr.ready "uri=$cr_url"
