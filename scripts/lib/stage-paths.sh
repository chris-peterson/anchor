#!/usr/bin/env bash
# Path-scoped staging, shared by the flows that stage before a review or a commit.
#
# Sourced, not executed. Why not `git add -A`: a checkout can be shared by more
# than one agent session, and a whole-tree add stages whatever the others have in
# flight. Their edits then ride into this session's review and land in a commit
# whose message does not describe them, and nobody sees it happen — the stat line
# and the diff both look like one coherent changeset. So a caller names the paths
# it changed and nothing else moves.
#
# Paths are **repo-root-relative**, and every pathspec below is root-anchored
# (`:/`, `:(exclude,top)`) so a caller in a subdirectory means the same thing as
# one at the top. An absolute path is refused rather than converted: matching it
# back against the root is exactly where macOS's /var vs /private/var skew turns a
# staged file into a silently missing one.

# anchor_reject_absolute <caller> [<path>...]
anchor_reject_absolute() {
  local caller="$1"; shift
  local p
  for p in "$@"; do
    case "$p" in
      /*) echo "$caller: --path must be relative to the repo root ($(git rev-parse --show-toplevel)), got: $p" >&2
          return 64 ;;
    esac
  done
}

# anchor_stage_paths <caller> [<path>...]
# Stage exactly <path>..., or nothing when none are given.
#
# A path with nothing to stage is an error, not a no-op: it is a caller naming a
# file it believes it changed, so the likely causes are a typo or a path relative
# to the wrong directory — both of which would otherwise drop that file from the
# commit with no sign that anything was left behind.
anchor_stage_paths() {
  local caller="$1"; shift
  [[ $# -gt 0 ]] || return 0
  anchor_reject_absolute "$caller" "$@" || return $?
  local p
  local -a specs=()
  for p in "$@"; do
    if [[ -z "$(git status --porcelain -- ":/$p")" ]]; then
      echo "$caller: --path names nothing changed: $p" >&2
      return 65
    fi
    specs+=(":/$p")
  done
  git add -- "${specs[@]}"
}

# anchor_other_staged_count [<path>...]
# How many staged paths this call did not stage — another session's in-flight work
# in a shared checkout. With no paths every staged path counts, which is the
# honest answer for a caller that staged nothing itself.
anchor_other_staged_count() {
  local p
  local -a specs=(':/')
  for p in "$@"; do specs+=(":(exclude,top)$p"); done
  git diff --cached --name-only -- "${specs[@]}" | grep -c . || true
}

# anchor_commit_pathspecs [<path>...]
# The `--` pathspec list for a scoped commit, root-anchored. Empty output means
# the caller named no paths, and the caller decides what that means.
anchor_commit_pathspecs() {
  local p
  for p in "$@"; do printf ':/%s\n' "$p"; done
}
