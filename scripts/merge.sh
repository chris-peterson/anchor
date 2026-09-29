#!/usr/bin/env bash
# Land a change request /anchor:merge has cleared, then leave the checkout on the
# target branch with the merged result: merge, read back what landed, announce
# it, check out and pull the target, delete the merged local branch.
#
# Why a script (not skill prose): once the user has said yes, every step is
# mechanical, and each forge needs its own flags to do it safely — the head-SHA
# guard, source-branch deletion, and on GitLab turning off the auto-merge glab
# enables while a pipeline runs. The gates and the method come from
# scripts/merge-gates.sh; this script takes them as given and does not re-decide.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>
#   MERGED=ok
#   CR_URL=<web url>
#   CR_TITLE=<title>
#   MERGED_AT=<forge timestamp>
#   MERGE_SHA=<sha>             the commit the merge landed, as the forge reports it
#   TARGET_BRANCH=<branch>
#   CLEANUP=<ok|incomplete>
#   CLEANUP_DETAIL=<why>        the step that stopped it, when incomplete
#
# A cleanup step that fails does not undo the merge, so it is reported through
# CLEANUP / CLEANUP_DETAIL and the script still exits 0.
#
# A merge the forge refused prints MERGE_ERROR=<message> on stderr and exits 70,
# with MERGE_AUTH=1 alongside it when the refusal is an authentication failure
# (retrying won't help; the credentials need refreshing).
#
# Usage:
#   merge.sh --cr 128 --sha <head> --method merge
#   merge.sh --cr 42 --sha <head> --method ff --squash 1 --repo /path/to/checkout

set -euo pipefail

here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/resolve-context.sh
source "$here/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$here/lib/forge-url.sh"

CTX_REPO=""
cr=""
sha=""
method=""
squash=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr)     cr="${2:?--cr needs a value}"; shift 2 ;;
    --sha)    sha="${2:?--sha needs a value}"; shift 2 ;;
    --method) method="${2:?--method needs a value}"; shift 2 ;;
    --squash) squash="${2:?--squash needs 0 or 1}"; shift 2 ;;
    --repo)   CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) echo "MERGE_ERROR=unrecognized argument: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$cr" && -n "$sha" && -n "$method" ]] \
  || { echo "MERGE_ERROR=--cr, --sha, and --method are required" >&2; exit 64; }

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

forge=$(anchor_forge_of_origin)
source_branch=$(git rev-parse --abbrev-ref HEAD)

refused() {
  echo "MERGE_ERROR=$1" >&2
  if grep -qiE '401|403|unauthori[sz]ed|forbidden|authentication|not logged in|gh auth login|glab auth login' <<<"$1"; then
    echo "MERGE_AUTH=1" >&2
  fi
  exit 70
}

case "$forge" in
  github)
    case "$method:$squash" in
      merge:0)  strategy=--merge ;;
      rebase:0) strategy=--rebase ;;
      *:1)      strategy=--squash ;;
      *) echo "MERGE_ERROR=--method must be merge, rebase, or squash on GitHub, got: $method" >&2; exit 64 ;;
    esac
    # gh's --delete-branch also deletes the local branch and switches off it, so
    # the cleanup below finds some of its work already done.
    out=$(gh pr merge "$cr" "$strategy" --delete-branch --match-head-commit "$sha" 2>&1) \
      || refused "$out"
    view=$(gh pr view "$cr" --json url,title,state,mergedAt,mergeCommit,baseRefName,headRefName 2>&1) \
      || refused "merged, but could not read it back: $view"
    readback=$(jq -r '[.url, .title, .state, .mergedAt, (.mergeCommit.oid // ""), .baseRefName, .headRefName] | @tsv' <<<"$view")
    ;;
  gitlab)
    # The project's merge method (merge commit, semi-linear, fast-forward) is
    # applied by the forge; --squash is the only per-merge override.
    flags=(--remove-source-branch --sha "$sha" --yes --auto-merge=false)
    [[ "$squash" == 1 ]] && flags+=(--squash)
    out=$(glab mr merge "$cr" "${flags[@]}" 2>&1) || refused "$out"
    view=$(glab mr view "$cr" --output json 2>&1) \
      || refused "merged, but could not read it back: $view"
    readback=$(jq -r '[.web_url, .title, .state, .merged_at,
                       (.merge_commit_sha // .squash_commit_sha // .sha),
                       .target_branch, .source_branch] | @tsv' <<<"$view")
    ;;
  *) echo "MERGE_ERROR=origin is neither GitHub nor GitLab" >&2; exit 69 ;;
esac

IFS=$'\t' read -r url title state merged_at landed target source <<<"$readback"
case "$state" in
  MERGED|merged) ;;
  *) refused "the forge accepted the merge but reports the CR as $state: $out" ;;
esac

echo "MERGED=ok"
echo "CR_URL=$url"
echo "CR_TITLE=$title"
echo "MERGED_AT=$merged_at"
echo "MERGE_SHA=$landed"
echo "TARGET_BRANCH=$target"

# The timestamp and the landed commit are the forge's, so a subscriber records
# when the merge happened rather than when it heard about it.
bash "$here/announce.sh" cr.merged "uri=$url" "title=$title" "merged_at=$merged_at" "sha=$landed"

# --- Cleanup ----------------------------------------------------------------

incomplete() { echo "CLEANUP=incomplete"; echo "CLEANUP_DETAIL=$1"; exit 0; }

err=$(git checkout --quiet "$target" 2>&1) || incomplete "could not check out $target: $err"
err=$(git pull --quiet --ff-only 2>&1)     || incomplete "could not fast-forward $target: $err"

[[ -n "$source" ]] || source="$source_branch"
if git show-ref --verify --quiet "refs/heads/$source"; then
  if ! err=$(git branch -d "$source" 2>&1); then
    # A squash or a rebase lands the branch's work under new SHAs, so -d can't
    # see it in the target. The forge has just confirmed the merge, which is
    # the evidence -d is asking for.
    if [[ "$squash" == 1 || "$method" == rebase ]]; then
      err=$(git branch -D "$source" 2>&1) || incomplete "could not delete $source: $err"
    else
      incomplete "git branch -d refused $source: $err"
    fi
  fi
fi

echo "CLEANUP=ok"
