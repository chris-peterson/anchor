#!/usr/bin/env bash
# One-shot pre-flight recon for /anchor:commit: stages, then gathers everything
# Steps 1-3 need to decide the route, and prints it as a single KEY=value block
# so the skill reads one command's output instead of running stage + stat +
# look-ahead + squash-check + branch/default + config as separate visible calls.
# Fewer calls, less to narrate — the review preview comes sooner.
#
# It does NOT read the full staged diff: the model needs that verbatim to draft
# the message, so the skill reads `git diff --cached` itself. Tests run earlier
# (their output must show), so they stay out of here too.
#
# --repo / --worktree <path> retargets onto a checkout other than the cwd repo
# (see scripts/lib/resolve-context.sh).
#
# Output (KEY=value on stdout):
#   STAGED=<0|1>            1 == something is staged after `git add -A`
#   STAT=<summary>          the `git diff --cached --stat` total line (empty if nothing staged)
#   BRANCH=<name>           current branch (empty on detached HEAD)
#   DEFAULT_BRANCH=<name>   origin/HEAD -> main -> master (empty if none resolve)
#   ON_DEFAULT_BRANCH=<0|1> 1 == BRANCH is the default branch
#   AHEAD=<n>               unpushed commit count (empty when no upstream)
#   SQUASH=<allowed|blocked> ... plus SQUASH_FORCE_PUSH / ALLOW_MESSAGE_AMEND /
#                            PRIOR_SUBJECT — emitted verbatim by squash-check.sh
#   ANCHOR_CONFIG=<json>    the anchor.* keys as a JSON object ({} when none)

set -euo pipefail

here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/resolve-context.sh
source "$here/lib/resolve-context.sh"
CTX_REPO=""
CTX_WORKTREE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
    *) echo "commit-preflight.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
ctx_resolve_repo

git add -A

staged=0
if ! git diff --cached --quiet; then staged=1; fi
stat=""
[[ "$staged" -eq 1 ]] && stat=$(git diff --cached --stat | tail -1 | sed 's/^[[:space:]]*//')

branch=$(git branch --show-current 2>/dev/null || true)

default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' || true)
if [[ -z "$default_branch" ]]; then
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    default_branch=main
  elif git rev-parse --verify --quiet origin/master >/dev/null; then
    default_branch=master
  fi
fi

on_default=0
[[ -n "$branch" && "$branch" == "$default_branch" ]] && on_default=1

ahead=$(bash "$here/look-ahead.sh" 2>/dev/null || true)

config_json=$(git config --get-regexp '^anchor\.' 2>/dev/null \
  | jq -cRn '[inputs | capture("^(?<k>[^ ]+) (?<v>.*)$")] | map({(.k): .v}) | add // {}' \
  || echo '{}')

echo "STAGED=$staged"
echo "STAT=$stat"
echo "BRANCH=$branch"
echo "DEFAULT_BRANCH=$default_branch"
echo "ON_DEFAULT_BRANCH=$on_default"
echo "AHEAD=$ahead"
# squash-check emits SQUASH / SQUASH_FORCE_PUSH / ALLOW_MESSAGE_AMEND / PRIOR_SUBJECT.
# Runs in this script's cwd (already the target repo), so it needs no --repo.
bash "$here/squash-check.sh"
echo "ANCHOR_CONFIG=$config_json"
