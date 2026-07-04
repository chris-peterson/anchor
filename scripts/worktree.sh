#!/usr/bin/env bash
# Flow-owned git-worktree lifecycle for operating on a repo other than the one
# backing the session's working directory.
#
# The rule (from the "should I use a worktree?" review note): when work targets
# the repo you started the session in, operate directly; when it targets a
# *different* repo — someone else's checkout, which may have its own branch and
# uncommitted state — isolate the work in a throwaway worktree rather than
# mutating that checkout. Sameness is judged by the git *common dir* (shared
# across a repo's worktrees), not the path, so a sibling worktree of the session
# repo still counts as "here".
#
# Lifecycle is owned by the *flow* (a skill), not by the per-operation scripts:
# a worktree created inside one script and removed on its exit would be gone
# before the skill's next Bash call, defeating the isolation. So the skill runs
# `setup` once, threads the resulting checkout through every subsequent command
# (as --worktree / `git -C`), and runs `teardown` when the flow ends.
#
# Usage:
#   worktree.sh setup <target-repo-path>
#     Decides direct-vs-worktree against the cwd repo, then prints a KEY=value
#     block on stdout:
#       RESOLVED_VIA=<repo|worktree>   repo == operate directly on <target>;
#                                      worktree == an isolated checkout was made
#       WORKTREE=<path>                the worktree to use (empty when RESOLVED_VIA=repo)
#       CHECKOUT=<path>                the path to operate in either way
#                                      (<target> when direct, the worktree when isolated)
#     On a bad target it prints CTX_ERROR=… on stderr and exits 66.
#
#   worktree.sh teardown <target-repo-path> <worktree-path>
#     Removes the worktree (git worktree remove --force), run from <target> so
#     git isn't asked to remove the tree it's standing in. Idempotent-ish: a
#     missing worktree is reported, not fatal.

set -euo pipefail

# Absolute git common dir for a checkout, or empty when it isn't a repo. The
# common dir is shared by every worktree of a repo, so it's the identity to
# compare on.
common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

cmd="${1:?usage: worktree.sh <setup|teardown> ...}"
shift

case "$cmd" in
  setup)
    target="${1:?usage: worktree.sh setup <target-repo-path>}"
    if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "CTX_ERROR=target is not a git working tree: $target" >&2
      exit 66
    fi

    here=$(common_dir .)
    there=$(common_dir "$target")

    if [[ -n "$here" && "$here" == "$there" ]]; then
      # Same repo as the session cwd (or a sibling worktree of it) — operate directly.
      echo "RESOLVED_VIA=repo"
      echo "WORKTREE="
      echo "CHECKOUT=$target"
      exit 0
    fi

    # Different repo: isolate on the target's current branch. --force lets the
    # worktree share a branch that's already checked out in the target's own
    # working copy (the common case — you committed there, now you're opening the
    # CR); committing/pushing here advances that shared branch (the work landing),
    # while the target's working-tree files are left untouched.
    branch=$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [[ -z "$branch" ]]; then
      echo "CTX_ERROR=could not resolve a branch to check out in $target" >&2
      exit 66
    fi
    wt=$(mktemp -u "${TMPDIR:-/tmp}/anchor-worktree-XXXXXX")
    if ! err=$(git -C "$target" worktree add --force "$wt" "$branch" 2>&1); then
      echo "CTX_ERROR=git worktree add failed: $err" >&2
      exit 66
    fi
    echo "RESOLVED_VIA=worktree"
    echo "WORKTREE=$wt"
    echo "CHECKOUT=$wt"
    ;;

  teardown)
    target="${1:?usage: worktree.sh teardown <target-repo-path> <worktree-path>}"
    wt="${2:?usage: worktree.sh teardown <target-repo-path> <worktree-path>}"
    if err=$(git -C "$target" worktree remove --force "$wt" 2>&1); then
      echo "WORKTREE_REMOVED=$wt"
    else
      echo "WORKTREE_REMOVE_ERROR=$err" >&2
      exit 1
    fi
    ;;

  *)
    echo "worktree.sh: unknown command: $cmd (expected setup|teardown)" >&2
    exit 64
    ;;
esac
