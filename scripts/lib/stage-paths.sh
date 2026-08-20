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
#
# Only the worktree half of a path is stageable, and `git status --porcelain`
# reports it in the second column: blank there means the path is already fully
# staged. Naming such a path in `git add` is fatal — exit 128, "did not match any
# files" — whenever nothing it matches is still on disk, which is the case for a
# staged deletion and for the old half of a staged rename. One bad pathspec aborts
# the whole `git add`, so a single such path would drop every other path in the
# list. Hence: a path with an unstaged change is staged, a path already fully
# staged is skipped, and only a path with no status at all is the typo error.
# Callers stage the same list more than once by design (a review needs new files
# in the index before `git diff HEAD` will show them), so this has to hold on the
# second call as much as the first.
anchor_stage_paths() {
  local caller="$1"; shift
  [[ $# -gt 0 ]] || return 0
  anchor_reject_absolute "$caller" "$@" || return $?
  local p st line
  local -a specs=()
  for p in "$@"; do
    st="$(git status --porcelain -- ":/$p")"
    if [[ -z "$st" ]]; then
      echo "$caller: --path names nothing changed: $p" >&2
      return 65
    fi
    # A directory pathspec reports a line per entry; one unstaged entry is enough.
    while IFS= read -r line; do
      if [[ "${line:1:1}" != " " ]]; then
        specs+=(":/$p")
        break
      fi
    done <<< "$st"
  done
  [[ ${#specs[@]} -gt 0 ]] || return 0
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
