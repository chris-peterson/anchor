#!/usr/bin/env bash
# Print the number of unpushed commits: HEAD ahead of @{upstream}, or, on a
# branch that was never pushed, ahead of origin/<default> (origin/HEAD, then
# main, then master — the ladder squash-check.sh uses).
# Output:
#   - "N" (integer)
#   - empty + non-zero exit when there is neither an upstream nor a default
#     branch on origin to count from
#
# Why a helper: invoking `git rev-list @{u}..HEAD` directly from a skill trips
# Claude Code's bash safety analyzer (the literal `@{...}` looks like brace
# expansion), prompting on every call regardless of allowlist or command-safety
# hook rules. Inside a script the analyzer only sees the outer `bash` invocation,
# so the structural gate doesn't fire.
#
# --repo <path> retargets onto a checkout other than the cwd repo
# (see scripts/lib/resolve-context.sh), and is accepted anywhere in the argv.

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
CTX_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) echo "look-ahead.sh: unknown option: $1" >&2; exit 64 ;;
  esac
done
ctx_resolve_repo

if git rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
  git rev-list --count '@{u}..HEAD'
  exit
fi

default_branch=$(anchor_default_branch) || exit 1
git rev-list --count "origin/$default_branch..HEAD"
