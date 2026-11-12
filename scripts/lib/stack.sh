#!/usr/bin/env bash
# Which branch a change is measured against when it is stacked on another CR.
#
# Sourced, not executed. A stacked branch is cut from another branch that has an
# open CR of its own, and its CR targets that branch so its diff holds only its
# own commits. Measured against the default branch instead, the predecessor's
# commits count as this branch's: they inflate AHEAD, land in the review range,
# and a CR opened against the default branch shows both changesets at once.
#
# Requires the caller to have sourced lib/resolve-context.sh and to be running
# inside the checkout.

# The open CRs of origin's project, one per line as
# "<head branch>\t<head sha>\t<number>\t<web url>\t<target branch>\t<draft: true|false>\t<author>".
# Prints a message on stderr and returns 1 when the forge can't be asked.
anchor_open_crs() {
  local forge=$1 out
  case "$forge" in
    github)
      out=$(gh pr list --state open --limit 100 --json headRefName,headRefOid,number,url,baseRefName,isDraft,author 2>&1) \
        || { printf 'gh pr list failed: %s\n' "$(head -1 <<<"$out")" >&2; return 1; }
      jq -r '.[] | [.headRefName, .headRefOid, (.number | tostring), .url, .baseRefName, (.isDraft // false | tostring), (.author.login // "")] | @tsv' <<<"$out" ;;
    gitlab)
      out=$(glab mr list --output json --per-page 100 2>&1) \
        || { printf 'glab mr list failed: %s\n' "$(head -1 <<<"$out")" >&2; return 1; }
      jq -r '.[] | [.source_branch, .sha, (.iid | tostring), .web_url, .target_branch, (.draft // false | tostring), (.author.username // "")] | @tsv' <<<"$out" ;;
    *) return 0 ;;
  esac
}

# From the open CRs on stdin (anchor_open_crs's lines), print the one HEAD is
# stacked on: the CR whose branch shares commits with HEAD beyond
# origin/<default>, and of those the nearest, so a chain B -> A -> main picks B.
# Prints nothing when HEAD sits directly on the default branch.
#
# Sharing commits is read through the merge base rather than "the predecessor's
# head is in HEAD", so a predecessor that took review fixes after this branch was
# cut still counts. A CR that targets this branch, or whose branch holds all of
# HEAD, is stacked on this one rather than under it, and is skipped: once both
# branches have commits of their own, the shared ones read the same from
# either side, and only the CR's target says which way the stack runs.
#
# A third argument measures that commit instead of HEAD, for a branch that isn't
# checked out.
anchor_stack_pick() {
  local branch=$1 default=$2 tip=${3:-HEAD} head sha num url target ref mb n best="" best_n=""
  git rev-parse --verify --quiet "origin/${default}^{commit}" >/dev/null || return 0
  while IFS=$'\t' read -r head sha num url target _; do
    [[ -n "$head" && "$head" != "$branch" && "$head" != "$default" && "$target" != "$branch" ]] || continue
    if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      ref=$sha
    elif git rev-parse --verify --quiet "refs/remotes/origin/${head}" >/dev/null; then
      ref="origin/${head}"
    else
      continue
    fi
    mb=$(git merge-base "$ref" "$tip" 2>/dev/null) || continue
    git merge-base --is-ancestor "$mb" "origin/${default}" && continue
    n=$(git rev-list --count "${mb}..${tip}")
    [[ "$n" -gt 0 ]] || continue
    if [[ -z "$best_n" || "$n" -lt "$best_n" ]]; then
      best_n=$n
      best="${head}"$'\t'"${num}"$'\t'"${url}"
    fi
  done
  [[ -z "$best" ]] || printf '%s\n' "$best"
}

# The branch a branch with no CR of its own is measured from: the branch of the
# open CR it is stacked on, else <default>. Prints a message on stderr and
# returns 1 when the open CRs can't be listed, rather than reading a stacked
# branch as based on the default branch.
anchor_branch_base() {
  local forge=$1 branch=$2 default=$3 open_crs stack
  open_crs=$(anchor_open_crs "$forge") || return 1
  stack=$(anchor_stack_pick "$branch" "$default" <<<"$open_crs")
  if [[ -n "$stack" ]]; then
    printf '%s\n' "${stack%%$'\t'*}"
  else
    printf '%s\n' "$default"
  fi
}
