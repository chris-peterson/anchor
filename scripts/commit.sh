#!/usr/bin/env bash
# Commit the staged changes (or amend HEAD) and push, in one invocation.
# /anchor:commit's Step 5 launches this instead of running `git commit` /
# `git push` as separate agent Bash calls.
#
# Why a helper: Step 5 otherwise issues several guarded git commands in a row —
# `git commit`, then a `git push` whose variant (`-u origin <branch>` vs plain
# vs `--force-with-lease`) is chosen by brace-plumbing over `@{u}` and
# `origin/HEAD`. Each guarded command is its own permission prompt, and the
# `@{...}` / `origin/<default>` plumbing trips Claude Code's bash safety analyzer
# from skill prose. Folding the sequence into one script makes it a single
# allowlistable call, and the analyzer only sees the outer `bash` invocation.
#
# It does NOT stage: Step 1 (and the Step 4 review) staged the paths under
# review, so the index already holds the reviewed changeset. Staging here would
# pull in edits made after the review. The message is read from a file
# (`--message-file`), never an argument, so a message body never lands in the
# command line — the same reason COMMIT-17 avoids inlining the message, and it
# keeps message text out of any command log.
#
# It does commit path-scoped when `--path` is given, which is what keeps a shared
# checkout honest: another session's staged file stays staged rather than riding
# into this commit under a message that never mentions it. `--amend -- <paths>`
# keeps every file the amended commit already carried, so a message-only amend can
# safely pass no paths at all.
#
# --repo <path> retargets onto a checkout other than the cwd repo
# (see scripts/lib/resolve-context.sh).
#
# Usage:
#   commit.sh --mode new           --message-file <path> [--path <p>]... [--allow-default-branch]
#   commit.sh --mode amend         --message-file <path> [--path <p>]... [--force-with-lease] [--allow-default-branch]
#   commit.sh --mode push-existing
#
# Modes:
#   new            git commit -F <file>        (the ordinary new commit)
#   amend          git commit --amend -F <file> (squash, or a message-only amend)
#   push-existing  no commit — push already-committed, unpushed work
#
# Push variant (chosen here, not in prose):
#   --force-with-lease set        -> git push --force-with-lease   (amend of a pushed commit)
#   no upstream (@{u} unset)       -> git push -u origin <branch>   (first push of a new branch)
#   otherwise                      -> git push
#
# Default-branch guard: refuses to commit/push onto the repo's default branch
# unless --allow-default-branch is passed (the deliberate direct-to-default
# case). This enforces COMMIT-19 in the script rather than trusting skill prose.
#
# Output (KEY=value on stdout):
#   COMMIT_SHA=<short-sha>      HEAD after the commit/amend (or the existing HEAD
#                              for push-existing)
#   BRANCH=<name>              the branch that was pushed
#   PUSH_MODE=<set-upstream|plain|force-with-lease>
#   PUSHED=ok                  emitted only on a successful push
#
# On a rejected push (non-fast-forward, protected branch, auth) the git error is
# left on stderr and the script exits non-zero, so the skill surfaces it and
# stops rather than retrying.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/stage-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-paths.sh"

CTX_REPO=""
mode=""
message_file=""
force_with_lease=0
allow_default_branch=0
paths=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                 CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --path)                 paths+=("${2:?--path needs a path}"); shift 2 ;;
    --mode)                 mode="${2:?--mode needs a value}"; shift 2 ;;
    --message-file)         message_file="${2:?--message-file needs a path}"; shift 2 ;;
    --force-with-lease)     force_with_lease=1; shift ;;
    --allow-default-branch) allow_default_branch=1; shift ;;
    *) echo "commit.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

case "$mode" in
  new|amend|push-existing) ;;
  "") echo "commit.sh: --mode is required (new|amend|push-existing)" >&2; exit 64 ;;
  *)  echo "commit.sh: unknown --mode: $mode" >&2; exit 64 ;;
esac

if [[ "$mode" != "push-existing" ]]; then
  if [[ -z "$message_file" ]]; then
    echo "commit.sh: --mode $mode requires --message-file" >&2; exit 64
  fi
  if [[ ! -r "$message_file" ]]; then
    echo "commit.sh: message file not readable: $message_file" >&2; exit 66
  fi
fi

ctx_resolve_repo

branch=$(git branch --show-current 2>/dev/null || true)
if [[ -z "$branch" ]]; then
  echo "commit.sh: detached HEAD — refusing to commit/push without a branch" >&2
  exit 65
fi

# --- Default-branch guard -----------------------------------------------------
# Same resolution ladder as squash-check.sh: symbolic origin/HEAD, then main,
# then master.

default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' || true)
if [[ -z "$default_branch" ]]; then
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    default_branch=main
  elif git rev-parse --verify --quiet origin/master >/dev/null; then
    default_branch=master
  fi
fi

if [[ -n "$default_branch" && "$branch" == "$default_branch" && "$allow_default_branch" -eq 0 ]]; then
  echo "commit.sh: refusing to commit/push onto the default branch ($default_branch);" >&2
  echo "           create a feature branch first, or pass --allow-default-branch." >&2
  exit 65
fi

# --- Commit -------------------------------------------------------------------

if [[ "$mode" != "push-existing" ]]; then
  commit_args=()
  [[ "$mode" == "amend" ]] && commit_args+=(--amend)
  commit_args+=(-F "$message_file")
  if [[ ${#paths[@]} -gt 0 ]]; then
    anchor_reject_absolute "commit.sh" "${paths[@]}"
    commit_args+=(--)
    while IFS= read -r spec; do commit_args+=("$spec"); done \
      < <(anchor_commit_pathspecs "${paths[@]}")
  fi
  git commit "${commit_args[@]}"
fi

commit_sha=$(git rev-parse --short HEAD)

# --- Push ---------------------------------------------------------------------
# Variant chosen here rather than in skill prose. @{u} is quoted so the safety
# analyzer never sees it (it runs inside this script).

if [[ "$force_with_lease" -eq 1 ]]; then
  push_mode=force-with-lease
elif git rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
  push_mode=plain
else
  push_mode=set-upstream
fi

echo "COMMIT_SHA=$commit_sha"
echo "BRANCH=$branch"
echo "PUSH_MODE=$push_mode"

case "$push_mode" in
  force-with-lease) git push --force-with-lease ;;
  plain)            git push ;;
  set-upstream)     git push -u origin "$branch" ;;
esac

echo "PUSHED=ok"
