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
# Runs against the cwd repo by default; pass --repo <path> to target another
# checkout (see scripts/lib/resolve-context.sh).
#
# The stdout is an OUTPUT CONTRACT, not a fact dump: it exports the decision the
# skill acts on plus the one datum it must present, and keeps the facts that
# produced the decision (push state, CR state, author identity, the block reason)
# inside this script. The skill can't narrate what it never receives — so the
# gate stays quiet by construction rather than by a "don't say this" instruction
# the model can override. See guides/execute-quietly.md.
#
# Output lines (KEY=value, read from stdout):
#   SQUASH=<allowed|blocked>       allowed == amending HEAD is safe; the skill may
#                                   offer squash (gated further by relatedness).
#                                   blocked == present the ordinary new commit.
#   SQUASH_FORCE_PUSH=<0|1>        meaningful only when allowed: 1 == HEAD is
#                                   pushed (draft CR, or no CR), so the amend must
#                                   be followed by force-with-lease
#   ALLOW_MESSAGE_AMEND=<0|1>      1 == squash is blocked, but a message-only amend
#                                   is permitted here (the ready-CR case: the tree
#                                   is untouched, so a wrong *message* may be fixed
#                                   and force-pushed). Named by what it PERMITS, not
#                                   why — the reason itself never crosses the boundary
#   PRIOR_SUBJECT=<subject>        HEAD's subject line (for the squash option text)

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
CTX_REPO=""
CTX_WORKTREE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
    *) echo "squash-check.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
ctx_resolve_repo

# --- Forge (for the CR probe) -------------------------------------------------

origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
  *)            forge=none ;;
esac

# --- Author guard facts -------------------------------------------------------

head_author_email=$(git log -1 --format=%ae HEAD 2>/dev/null || true)
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

# The block reason, push state, and CR state below are LOCAL: they decide the
# contract but are never emitted. Only `squash`, `force_push`, and
# `allow_message_amend` cross the boundary — see the header's output contract.

squash=blocked
force_push=0
allow_message_amend=0

if [[ "$other_author" -eq 1 ]]; then
  # HEAD authored by someone else — amending rewrites their commit, never a target
  # (even for a message-only fix).
  :
elif [[ "$head_pushed" -eq 0 ]]; then
  # Unpushed HEAD: squashing never touches published or reviewed history.
  # (Local-only commits on the default branch land here too — fine to amend.)
  squash=allowed
elif [[ -n "$default_branch" ]] \
     && git rev-parse --verify --quiet "origin/${default_branch}" >/dev/null \
     && git merge-base --is-ancestor HEAD "origin/${default_branch}" 2>/dev/null; then
  # HEAD is reachable from origin/<default> — it's published shared history on the
  # default branch (the pushed default-branch tip, or a fresh feature branch whose
  # only commit so far IS that tip). Amending it force-pushes over origin/<default>,
  # which no review-state check makes safe. Land a new commit instead.
  :
elif [[ "$cr_state" == "ready" ]]; then
  # A ready CR is out for review, and a reviewer relies on the per-commit "changes
  # since" diff — force-pushing over it destroys that, so squash stays blocked. But
  # the tree is untouched by a message fix, so a demonstrably-wrong *message* may be
  # amended and force-pushed; the skill offers that only on the user's report.
  allow_message_amend=1
else
  # Pushed, but not out for review (draft CR, or no CR at all) — mutable history
  # is the norm; the amend is followed by force-push-with-lease.
  squash=allowed
  force_push=1
fi

# --- Emit --------------------------------------------------------------------

echo "SQUASH=$squash"
echo "SQUASH_FORCE_PUSH=$force_push"
echo "ALLOW_MESSAGE_AMEND=$allow_message_amend"
echo "PRIOR_SUBJECT=$prior_subject"
