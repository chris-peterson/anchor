#!/usr/bin/env bash
# Decide whether the staged changes may be squashed into HEAD (via
# `git commit --amend`), or must land as a new commit. Prints one KEY=value
# block on stdout so /anchor:commit's Step 3 reads a single command's output.
#
# The gate is "is HEAD out for review?" — the principled question underneath
# the squash decision:
#
#   - HEAD authored by someone else        -> never rewrite it (author guard)
#   - HEAD is unpushed                      -> squash freely (reviewer/remote
#                                              has never seen it)
#   - HEAD pushed, CR is a draft            -> squash (mutable-history norm;
#                                              the follow-up is force-push-with-lease)
#   - HEAD pushed, no CR                     -> squash (nothing is under review;
#                                              the follow-up is force-push-with-lease)
#   - HEAD is the pushed tip of the default -> DON'T squash — amending force-pushes
#     branch                                   over published shared history; no
#                                              review-state check makes that safe.
#                                              Land a new commit.
#   - HEAD pushed, CR is ready (out for     -> DON'T squash — a reviewer relies
#     review)                                  on the per-commit "changes since"
#                                              diff; land a new commit
#
# What it does NOT decide — the judgment that needs the model: whether the
# staged changes are a *related* follow-on to HEAD (→ squash when allowed) or an
# *unrelated* new topic (→ new commit). The script reports whether squash is
# permissible and the facts; the skill applies relatedness and picks the wording.
#
# The author guard holds regardless of review state: amending rewrites HEAD in
# place, so a commit someone else authored is never a squash target — even for a
# message-only fix.
#
# Run from the target repo (like look-ahead.sh / pipeline-status.sh); it reads
# the repo from the working directory.
#
# Output lines (KEY=value, read from stdout):
#   SQUASH_ALLOWED=<0|1>            1 == amending HEAD is safe; the skill may
#                                   offer squash (gated further by relatedness)
#   SQUASH_BLOCK_REASON=<reason>    why squash is off the table (empty when allowed):
#                                     other-author        HEAD authored by someone else
#                                     default-branch-tip  HEAD is the pushed tip of the
#                                                         default branch (published history)
#                                     cr-ready            pushed & the CR is out for review
#   SQUASH_NEEDS_FORCE_PUSH=<0|1>  1 == squash is allowed but HEAD is pushed, so
#                                   the amend must be followed by force-with-lease
#   HEAD_PUSHED=<0|1>              HEAD is on the remote tracking branch
#   UNPUSHED_COUNT=<n|>            commits HEAD is ahead of upstream (empty when
#                                   no upstream and no origin fallback resolved)
#   CR_STATE=<none|draft|ready>    the branch's open CR review state
#   HEAD_AUTHOR_EMAIL=<email>      HEAD's author (for the guard message)
#   HEAD_AUTHOR_NAME=<name>
#   USER_EMAIL=<email>             the current git identity compared against
#   PRIOR_SUBJECT=<subject>        HEAD's subject line (for the squash option text)

set -euo pipefail

# --- Forge (for the CR probe) -------------------------------------------------

origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
  *)            forge=none ;;
esac

# --- Author guard facts -------------------------------------------------------

head_author_email=$(git log -1 --format=%ae HEAD 2>/dev/null || true)
head_author_name=$(git log -1 --format=%an HEAD 2>/dev/null || true)
prior_subject=$(git log -1 --format=%s HEAD 2>/dev/null || true)
user_email=$(git config user.email 2>/dev/null || true)

other_author=0
if [[ -n "$head_author_email" && -n "$user_email" && "$head_author_email" != "$user_email" ]]; then
  other_author=1
fi

# --- Default branch (for the push probe and the default-branch guard) --------
# Resolved once so both the push probe below and the decision block can reuse it.

default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' || true)
if [[ -z "$default_branch" ]]; then
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    default_branch=main
  elif git rev-parse --verify --quiet origin/master >/dev/null; then
    default_branch=master
  fi
fi

# --- Is HEAD pushed? ----------------------------------------------------------
# Prefer the configured upstream; fall back to origin/<default> for local-only
# branches that were never `push -u`'d (the common "first commit on a new
# branch" case). With neither, treat HEAD as unpushed.

unpushed_count=""
if git rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
  unpushed_count=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo "")
elif [[ -n "$default_branch" ]] && git rev-parse --verify --quiet "origin/${default_branch}" >/dev/null; then
  unpushed_count=$(git rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || echo "")
fi

# HEAD is pushed only when we resolved a count and it's zero. No resolvable
# remote ref (unpushed_count empty) => local-only => unpushed.
head_pushed=0
if [[ -n "$unpushed_count" && "$unpushed_count" -eq 0 ]]; then
  head_pushed=1
fi

# --- CR review state ----------------------------------------------------------

cr_state=none
case "$forge" in
  gitlab)
    draft=$(glab mr view --output json 2>/dev/null | jq -r '.draft // empty' || true)
    ;;
  github)
    draft=$(gh pr view --json isDraft --jq '.isDraft' 2>/dev/null || true)
    ;;
  *)
    draft=""
    ;;
esac
if [[ "$draft" == "true" ]]; then
  cr_state=draft
elif [[ "$draft" == "false" ]]; then
  cr_state=ready
fi

# --- Decide ------------------------------------------------------------------

squash_allowed=0
block_reason=""
needs_force_push=0

if [[ "$other_author" -eq 1 ]]; then
  block_reason=other-author
elif [[ "$head_pushed" -eq 0 ]]; then
  # Unpushed HEAD: squashing never touches published or reviewed history.
  # (Local-only commits on the default branch land here too — fine to amend.)
  squash_allowed=1
elif [[ -n "$default_branch" ]] \
     && git rev-parse --verify --quiet "origin/${default_branch}" >/dev/null \
     && git merge-base --is-ancestor HEAD "origin/${default_branch}" 2>/dev/null; then
  # HEAD is reachable from origin/<default> — it's published shared history on the
  # default branch (the pushed default-branch tip, or a fresh feature branch whose
  # only commit so far IS that tip). Amending it force-pushes over origin/<default>,
  # which no review-state check makes safe. Land a new commit instead.
  block_reason=default-branch-tip
elif [[ "$cr_state" == "ready" ]]; then
  # The one block: a ready CR is out for review, and a reviewer relies on the
  # per-commit "changes since" diff — force-pushing over it destroys that.
  block_reason=cr-ready
else
  # Pushed, but not out for review (draft CR, or no CR at all) — mutable history
  # is the norm; the amend is followed by force-push-with-lease.
  squash_allowed=1
  needs_force_push=1
fi

# --- Emit --------------------------------------------------------------------

echo "SQUASH_ALLOWED=$squash_allowed"
echo "SQUASH_BLOCK_REASON=$block_reason"
echo "SQUASH_NEEDS_FORCE_PUSH=$needs_force_push"
echo "HEAD_PUSHED=$head_pushed"
echo "UNPUSHED_COUNT=$unpushed_count"
echo "CR_STATE=$cr_state"
echo "HEAD_AUTHOR_EMAIL=$head_author_email"
echo "HEAD_AUTHOR_NAME=$head_author_name"
echo "USER_EMAIL=$user_email"
echo "PRIOR_SUBJECT=$prior_subject"
