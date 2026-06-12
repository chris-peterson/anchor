#!/usr/bin/env bash
# Gather everything /prepare-review's Step 1 needs and perform the safe
# default-path actions, then print one KEY=value block on stdout so the skill
# acts on a single command's output — no per-step orchestration to narrate.
#
# Why a script (not skill prose): Step 1 is a string of deterministic recon and
# safe setup — detect the forge, resolve or open the draft CR, count the gap to
# the default branch, capture the current description, confirm local state
# matches the CR head, read the template and anchor config. Run from the skill
# each is its own tool call, and each is a slot where the model narrates "now
# let me…". Folding them into one launch-and-read removes the narration surface
# (the structural lever in skills-execute-dont-narrate) and keeps the brace
# tokens in `git rev-list '@{u}..HEAD'` inside a script, where Claude Code's
# bash safety analyzer doesn't fire.
#
# What it does NOT do — the decision points that need the model or the user:
#   - Rebase when behind (prompt, conflict resolution, force-push gating) — the
#     script reports BEHIND and stops short of rebasing.
#   - Force-push over a ready (non-draft) CR — reported via CR_DRAFT, gated by
#     the skill.
#   - Open a draft when one already exists, when HEAD is the default branch, or
#     when --no-open is passed — those resolve to the URL-free skip-deep-links
#     path.
#
# Output lines (KEY=value, read from stdout):
#   FORGE=<github|gitlab|none>
#   BRANCH=<current branch>
#   DEFAULT_BRANCH=<resolved default: origin/HEAD, else main, else master>
#   ON_DEFAULT_BRANCH=<0|1>      1 == HEAD is the default branch (no CR to open)
#   AHEAD=<n>                    commits HEAD is ahead of the default branch
#   BEHIND=<n>                   commits HEAD is behind — >0 means run the rebase dialog
#   CR_PREEXISTING=<0|1>         a CR was already open before this run
#   CR_CREATED=<0|1>             this script opened a draft CR
#   CR_URL=<web url>             empty on the skip-deep-links path
#   CR_IID=<iid/number>          empty when no CR
#   CR_DRAFT=<true|false|>       the CR's draft flag (empty when no CR)
#   CR_HEAD_SHA=<sha>            the CR head the reviewer sees (empty when no CR)
#   LOCAL_HEAD_SHA=<sha>         local HEAD
#   WORKTREE_CLEAN=<0|1>
#   STATE=<match|dirty|head-mismatch|dirty+head-mismatch>   drift vs the CR head
#   CURRENT_DESC_PATH=<path>     temp file holding the CR's current description
#                                (baseline for the Step 4 diff); empty when no CR
#   TEMPLATE_PATH=<path>         project CR template, empty when none
#   ANCHOR_CONFIG=<json>         {key: value} of anchor.* git config; {} when none
#   FILE_ANCHORS=<json>          {path: sha1(path)} for changed files (GitLab deep
#                                links); {} on GitHub (sha256, gh doesn't expose it)
#
# On an auth failure (or any failure) while opening the draft, it prints
# CR_CREATE_ERROR=<message> and exits non-zero so the skill surfaces it and asks
# the user to refresh credentials (the fail-fast-on-auth rule) rather than
# silently dropping to the URL-free path.
#
# Usage:
#   prepare-review.sh              # default: resolve CR, auto-open a draft if none
#   prepare-review.sh --no-open    # never auto-open; no CR -> skip-deep-links path

set -euo pipefail

auto_open=1
if [[ "${1:-}" == "--no-open" ]]; then
  auto_open=0
fi

# --- Forge + branch + default branch ----------------------------------------

origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
  *)            forge=none ;;
esac

branch=$(git rev-parse --abbrev-ref HEAD)

# Resolve the default branch: the symbolic origin/HEAD, then the conventional
# main and master.
default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' || true)
if [[ -z "$default_branch" ]]; then
  if git rev-parse --verify --quiet origin/main >/dev/null; then
    default_branch=main
  elif git rev-parse --verify --quiet origin/master >/dev/null; then
    default_branch=master
  else
    default_branch=main
  fi
fi

on_default=0
[[ "$branch" == "$default_branch" ]] && on_default=1

# --- Gap to the default branch -----------------------------------------------

git fetch origin "$default_branch" >/dev/null 2>&1 || true
ahead=$(git rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || echo 0)
behind=$(git rev-list --count "HEAD..origin/${default_branch}" 2>/dev/null || echo 0)

local_head=$(git rev-parse HEAD)

# --- Resolve (or open) the CR ------------------------------------------------

cr_url=""; cr_iid=""; cr_draft=""; cr_head=""; cr_desc=""
cr_preexisting=0; cr_created=0

# Pull a CR's url/iid/draft/headsha/description into the cr_* vars. Returns
# non-zero (leaving them empty) when no CR is open for the current branch.
resolve_cr() {
  case "$forge" in
    gitlab)
      local json
      json=$(glab mr view --output json 2>/dev/null) || return 1
      [[ -z "$json" ]] && return 1
      cr_url=$(jq -r '.web_url // empty' <<<"$json")
      [[ -z "$cr_url" ]] && return 1
      cr_iid=$(jq -r '.iid // empty' <<<"$json")
      cr_draft=$(jq -r '.draft // empty' <<<"$json")
      cr_head=$(jq -r '.sha // empty' <<<"$json")
      cr_desc=$(jq -r '.description // ""' <<<"$json")
      ;;
    github)
      local json
      json=$(gh pr view --json url,number,isDraft,headRefOid,body 2>/dev/null) || return 1
      [[ -z "$json" ]] && return 1
      cr_url=$(jq -r '.url // empty' <<<"$json")
      [[ -z "$cr_url" ]] && return 1
      cr_iid=$(jq -r '.number // empty' <<<"$json")
      cr_draft=$(jq -r '.isDraft // empty' <<<"$json")
      cr_head=$(jq -r '.headRefOid // empty' <<<"$json")
      cr_desc=$(jq -r '.body // ""' <<<"$json")
      ;;
    *) return 1 ;;
  esac
}

if [[ "$forge" != "none" && "$on_default" -eq 0 ]]; then
  if resolve_cr; then
    cr_preexisting=1
  elif [[ "$auto_open" -eq 1 ]]; then
    # No CR yet — open a draft, assigned to me, source branch deleted on merge.
    # Push first so the create call has a remote branch to target.
    if ! push_err=$(git push -u origin "$branch" 2>&1); then
      echo "CR_CREATE_ERROR=push failed: $push_err"
      exit 1
    fi
    case "$forge" in
      gitlab)
        username=$(glab api user 2>/dev/null | jq -r '.username // empty' || true)
        if ! create_err=$(glab mr create --draft --fill --yes \
              --target-branch "$default_branch" --remove-source-branch \
              --assignee "$username" 2>&1); then
          echo "CR_CREATE_ERROR=glab mr create failed: $create_err"
          exit 1
        fi
        ;;
      github)
        # Branch deletion on merge is a repo setting; pass --delete-branch to
        # `gh pr merge` at merge time if it's off.
        if ! create_err=$(gh pr create --draft --fill --assignee @me 2>&1); then
          echo "CR_CREATE_ERROR=gh pr create failed: $create_err"
          exit 1
        fi
        ;;
    esac
    # The create reported success, so the CR exists. If the re-resolve fails
    # (forge create→read lag), surface it rather than dropping to the URL-free
    # path — going silent here would misreport an opened CR as "no CR".
    if resolve_cr; then
      cr_created=1
    else
      echo "CR_CREATE_ERROR=opened the draft CR but could not resolve it back (forge lag?) — re-run prepare-review"
      exit 1
    fi
  fi
fi

# --- Capture the current description (baseline for the Step 4 diff) ----------

current_desc_path=""
if [[ -n "$cr_url" ]]; then
  current_desc_path=$(mktemp /tmp/cr-desc-current.XXXXXX.md)
  printf '%s' "$cr_desc" > "$current_desc_path"
fi

# --- State check: local tree vs the CR head ----------------------------------

worktree_clean=1
[[ -n "$(git status --porcelain)" ]] && worktree_clean=0

state="match"
head_mismatch=0
if [[ -n "$cr_head" && "$cr_head" != "$local_head" ]]; then
  head_mismatch=1
fi
if [[ "$worktree_clean" -eq 0 && "$head_mismatch" -eq 1 ]]; then
  state="dirty+head-mismatch"
elif [[ "$worktree_clean" -eq 0 ]]; then
  state="dirty"
elif [[ "$head_mismatch" -eq 1 ]]; then
  state="head-mismatch"
fi

# --- Project CR template ------------------------------------------------------

template_path=""
case "$forge" in
  gitlab)
    template_path=$(ls .gitlab/merge_request_templates/*.md 2>/dev/null | head -1 || true)
    ;;
  github)
    if [[ -f .github/pull_request_template.md ]]; then
      template_path=.github/pull_request_template.md
    else
      template_path=$(ls .github/PULL_REQUEST_TEMPLATE/*.md 2>/dev/null | head -1 || true)
    fi
    ;;
esac

# --- anchor.* config ----------------------------------------------------------

anchor_cfg='{}'
while read -r name value; do
  [[ -z "$name" ]] && continue
  anchor_cfg=$(jq -c --arg n "$name" --arg v "$value" '. + {($n): $v}' <<<"$anchor_cfg")
done < <(git config --get-regexp '^anchor\.' 2>/dev/null || true)

# --- File anchors for GitLab deep links (sha1 of each changed path) ----------

file_anchors='{}'
if [[ "$forge" == "gitlab" && "$ahead" -gt 0 ]]; then
  while read -r path; do
    [[ -z "$path" ]] && continue
    sha=$(printf '%s' "$path" | sha1sum | cut -d' ' -f1)
    file_anchors=$(jq -c --arg p "$path" --arg s "$sha" '. + {($p): $s}' <<<"$file_anchors")
  done < <(git diff --name-only "origin/${default_branch}...HEAD" 2>/dev/null || true)
fi

# --- Emit ---------------------------------------------------------------------

echo "FORGE=$forge"
echo "BRANCH=$branch"
echo "DEFAULT_BRANCH=$default_branch"
echo "ON_DEFAULT_BRANCH=$on_default"
echo "AHEAD=$ahead"
echo "BEHIND=$behind"
echo "CR_PREEXISTING=$cr_preexisting"
echo "CR_CREATED=$cr_created"
echo "CR_URL=$cr_url"
echo "CR_IID=$cr_iid"
echo "CR_DRAFT=$cr_draft"
echo "CR_HEAD_SHA=$cr_head"
echo "LOCAL_HEAD_SHA=$local_head"
echo "WORKTREE_CLEAN=$worktree_clean"
echo "STATE=$state"
echo "CURRENT_DESC_PATH=$current_desc_path"
echo "TEMPLATE_PATH=$template_path"
echo "ANCHOR_CONFIG=$anchor_cfg"
echo "FILE_ANCHORS=$file_anchors"
