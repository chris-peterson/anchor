#!/usr/bin/env bash
# Clear a change request's draft flag, and announce that it happened.
#
# Two skills reach this moment from different directions — the self-review
# handoff in /anchor:review, where the author is done and wants eyes on it, and
# /anchor:merge's draft gate, where they are landing one that never left draft —
# and a subscriber cannot tell those apart, nor should it have to. Both call
# here, so `cr.ready` has one emission point and one shape.
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
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>   which checkout the run operated in
#   CR_URL=<web url>          the CR, as the forge reports it
#   CR_READY=ok               the flag was set on this run
#   ALREADY_READY=1           it was already clear, so nothing was changed
#
# On a failure it prints READY_ERROR=<message> and exits non-zero rather than
# leaving a caller to read success out of an empty block.
#
# Usage:
#   mark-ready.sh --forge github --cr 128
#   mark-ready.sh --forge gitlab --cr 42 --repo /path/to/checkout

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"

CTX_REPO=""
forge=""
cr=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) forge="${2:-}"; shift 2 ;;
    --cr)    cr="${2:-}";    shift 2 ;;
    --repo)  CTX_REPO="${2:-}"; shift 2 ;;
    *) echo "READY_ERROR=unrecognized argument: $1" >&2; exit 64 ;;
  esac
done

case "$forge" in
  github|gitlab) ;;
  "") echo "READY_ERROR=--forge is required (github|gitlab)" >&2; exit 64 ;;
  *)  echo "READY_ERROR=--forge must be github or gitlab, got: $forge" >&2; exit 64 ;;
esac
[[ -n "$cr" ]] || { echo "READY_ERROR=--cr is required" >&2; exit 64; }

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

if [[ "$forge" == github ]]; then
  if ! view=$(gh pr view "$cr" --json url,isDraft 2>&1); then
    echo "READY_ERROR=could not read CR $cr: $view" >&2
    exit 70
  fi
  cr_url=$(printf '%s' "$view" | jq -r '.url // ""')
  draft=$(printf '%s' "$view" | jq -r '.isDraft // false')
else
  if ! view=$(glab mr view "$cr" --output json 2>&1); then
    echo "READY_ERROR=could not read CR $cr: $view" >&2
    exit 70
  fi
  cr_url=$(printf '%s' "$view" | jq -r '.web_url // ""')
  draft=$(printf '%s' "$view" | jq -r '.draft // false')
fi

echo "CR_URL=$cr_url"

if [[ "$draft" != "true" ]]; then
  echo "ALREADY_READY=1"
  exit 0
fi

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
