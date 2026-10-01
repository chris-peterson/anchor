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
# command line, where a hook matching its words would block the commit, and it
# stays out of any command log.
#
# It does commit path-scoped when `--path` is given, which is what keeps a shared
# checkout honest: another session's staged file stays staged rather than riding
# into this commit under a message that never mentions it. What it commits for
# each path is the staged content, so a partly staged file lands as staged, and
# `--staged-path` is accepted as the same flag so the skill carries one list. An
# amend keeps every file the amended commit already carried, so a message-only
# amend can safely pass no paths at all.
#
# --reviewed-index <id> takes the REVIEW_INDEX the review printed and refuses
# (exit 68) when the named paths' index entries no longer match it, so a `git
# add` between the review and the commit cannot ship unreviewed. It is required
# with --path: a tree change is always reviewed first, and only the message-only
# amend, which has none, names no paths.
#
# --repo <path> retargets onto a checkout other than the cwd repo
# (see scripts/lib/resolve-context.sh).
#
# Usage:
#   commit.sh --mode new           --message-file <path> [--reviewed-index <id> --path <p>...] [--allow-default-branch]
#   commit.sh --mode amend         --message-file <path> [--reviewed-index <id> --path <p>...] [--force-with-lease] [--allow-default-branch]
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
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"

CTX_REPO=""
mode=""
message_file=""
force_with_lease=0
allow_default_branch=0
reviewed_index=""
paths=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                 CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --path|--staged-path)   paths+=("${2:?$1 needs a path}"); shift 2 ;;
    --mode)                 mode="${2:?--mode needs a value}"; shift 2 ;;
    --message-file)         message_file="${2:?--message-file needs a path}"; shift 2 ;;
    --force-with-lease)     force_with_lease=1; shift ;;
    --allow-default-branch) allow_default_branch=1; shift ;;
    --reviewed-index)       reviewed_index="${2:?--reviewed-index needs the REVIEW_INDEX the review printed}"; shift 2 ;;
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
  if [[ ${#paths[@]} -gt 0 && -z "$reviewed_index" ]]; then
    echo "commit.sh: --path requires --reviewed-index, the REVIEW_INDEX the review printed" >&2; exit 64
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
  # A named rename destination carries its source, so the commit can't land the
  # add without the delete. The review did the same, so the digest matches.
  while IFS= read -r src; do paths+=("$src"); done \
    < <(anchor_rename_sources "${paths[@]+"${paths[@]}"}")
  if [[ -n "$reviewed_index" ]]; then
    anchor_reject_absolute "commit.sh" "${paths[@]+"${paths[@]}"}"
    if [[ "$(anchor_index_digest "${paths[@]+"${paths[@]}"}")" != "$reviewed_index" ]]; then
      echo "commit.sh: the index for these paths changed after the review; nothing was committed. Review again and pass the new REVIEW_INDEX." >&2
      exit 68
    fi
  fi
  # The squash gate was read at the start of the flow, and a CR can be marked
  # ready while its review is open. Read it again where the rewrite happens.
  if [[ "$mode" == "amend" ]]; then
    gate=$(bash "$(dirname "${BASH_SOURCE[0]}")/squash-check.sh")
    if ! grep -qx 'SQUASH=allowed' <<<"$gate" \
       && ! { [[ ${#paths[@]} -eq 0 ]] && grep -qx 'ALLOW_MESSAGE_AMEND=1' <<<"$gate"; }; then
      echo "commit.sh: HEAD can no longer be amended (it is out for review, pushed to the default branch, or not yours); nothing was committed. Land the change as a new commit." >&2
      exit 69
    fi
  fi
  commit_args=()
  [[ "$mode" == "amend" ]] && commit_args+=(--amend)
  commit_args+=(-F "$message_file")
  if [[ ${#paths[@]} -gt 0 ]]; then
    anchor_reject_absolute "commit.sh" "${paths[@]}"
    specs=()
    while IFS= read -r spec; do specs+=("$spec"); done \
      < <(anchor_commit_pathspecs "${paths[@]}")
    # `git commit -- <paths>` commits the working-tree copy of each path, which
    # carries a partly staged file's unstaged hunks and any edit made after the
    # review. So the commit is built from a scratch index: HEAD, plus the named
    # paths' entries from the real index. Every other staged path stays out.
    commit_index=$(anchor_tmpfile anchor-commit-index index)
    trap 'rm -f "$commit_index"' EXIT
    base=HEAD
    git rev-parse --verify --quiet HEAD >/dev/null || base=$(git hash-object -t tree /dev/null)
    GIT_INDEX_FILE="$commit_index" git read-tree "$base"
    git diff --cached --no-renames --no-abbrev --raw -z "$base" -- "${specs[@]}" \
      | while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
          read -r _ new_mode _ new_sha _ <<<"$meta"
          printf '%s %s\t%s\0' "$new_mode" "$new_sha" "$path"
        done \
      | GIT_INDEX_FILE="$commit_index" git update-index -z --index-info
    reviewed_tree=$(GIT_INDEX_FILE="$commit_index" git write-tree)
    GIT_INDEX_FILE="$commit_index" git commit "${commit_args[@]}"
    # A pre-commit hook runs against this same index, so a hook that stages a
    # file puts it in the commit unreviewed. Stop before the push and name it.
    if [[ "$(git rev-parse 'HEAD^{tree}')" != "$reviewed_tree" ]]; then
      echo "COMMIT_SHA=$(git rev-parse --short HEAD)"
      echo "commit.sh: a git hook changed the commit after the review; it is committed locally and not pushed. Paths the hook changed:" >&2
      git diff --name-only "$reviewed_tree" 'HEAD^{tree}' | sed 's/^/  /' >&2
      exit 71
    fi
  else
    # An amend that names no paths changes the message only; --only keeps
    # whatever else is staged, another session's work included, out of it.
    [[ "$mode" != "amend" ]] || commit_args+=(--only)
    git commit "${commit_args[@]}"
  fi
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

# --- Announce -----------------------------------------------------------------
# The push is what makes the commit reachable, so the announcement sits after it
# rather than in the skill: a run the skill doesn't finish still pushed.
#
# The URI carries the project as well as the sha, which is why no separate repo
# field is needed; it is empty where `origin` is not a forge anchor can address.
"$(dirname "${BASH_SOURCE[0]}")/announce.sh" commit.pushed \
  "uri=$(anchor_commit_web_url "$commit_sha")" \
  "sha=$commit_sha" \
  "branch=$branch"
