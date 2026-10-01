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

# anchor_refuse_partly_staged <caller> [<path>...]
# Refuse a --path that already has staged changes *and* unstaged ones. Someone
# staged part of that file on purpose, and a `git add` would fold the hunks they
# left out into the commit. The caller says which it means: --staged-path to keep
# the index as it is, or stage the rest itself.
anchor_refuse_partly_staged() {
  local caller="$1"; shift
  local p line
  for p in "$@"; do
    while IFS= read -r line; do
      case "${line:0:2}" in
        " "?|"??"|?" ") ;;
        *) echo "$caller: $p is partly staged; pass --staged-path $p to commit only its staged hunks, or stage the rest and pass --path" >&2
           return 67 ;;
      esac
    done < <(git status --porcelain -- ":/$p")
  done
}

# anchor_require_staged <caller> [<path>...]
# A --staged-path is taken from the index as it stands, so it has to have
# something staged — the same typo guard --path gets from COMMIT-04a.
anchor_require_staged() {
  local caller="$1"; shift
  [[ $# -gt 0 ]] || return 0
  anchor_reject_absolute "$caller" "$@" || return $?
  local p
  for p in "$@"; do
    if git diff --cached --quiet -- ":/$p"; then
      echo "$caller: --staged-path has nothing staged: $p" >&2
      return 65
    fi
  done
}

# anchor_rename_sources [<path>...]
# The source side of each staged rename whose destination is one of <path>...
# (or under one, for a directory), one per line. A rename is one change to git
# but two index entries, so a path list naming only the new name would commit
# the add and leave the delete behind: the tree ends up holding both names.
# Callers add these to their list rather than treating them as foreign work.
anchor_rename_sources() {
  [[ $# -gt 0 ]] || return 0
  local base=HEAD status src dst p
  git rev-parse --verify --quiet HEAD >/dev/null || return 0
  while IFS= read -r -d '' status && IFS= read -r -d '' src && IFS= read -r -d '' dst; do
    for p in "$@"; do
      p="${p%/}"
      if [[ "$dst" == "$p" || "$dst" == "$p"/* ]]; then
        printf '%s\n' "$src"
        break
      fi
    done
  done < <(git diff --cached -M --diff-filter=R --name-status -z "$base")
}

# anchor_diff_specs
# The root-anchored pathspecs for $diff_paths, the newline-separated paths a
# --local review was given, one per line. Empty when the review names none, which
# leaves it covering the whole tree.
anchor_diff_specs() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && printf ':/%s\n' "$p"
  done <<< "${diff_paths:-}"
}

# anchor_index_digest [<path>...]
# One id for what a commit of <path>... would carry: their index entries against
# HEAD, hashed. The review prints it and commit.sh checks it, so a `git add`
# between the two is caught rather than committed unreviewed. With no paths it
# covers every staged path, which is what a commit with no paths carries.
anchor_index_digest() {
  local base=HEAD
  git rev-parse --verify --quiet HEAD >/dev/null || base=$(git hash-object -t tree /dev/null)
  local -a specs=()
  local p
  for p in "$@"; do specs+=(":/$p"); done
  git diff --cached --no-renames --no-abbrev --raw "$base" -- "${specs[@]+"${specs[@]}"}" \
    | git hash-object --stdin
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
