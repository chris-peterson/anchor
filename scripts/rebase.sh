#!/usr/bin/env bash
# Rebase the checkout's branch on its base, or a stack of branches bottom-up,
# and force-push what was pushed before, for /anchor:rebase.
#
# Why a script (not skill prose): which base, which branches, which commits to
# replay, and whether a branch may be force-pushed are facts, and the push is a
# guarded command that prompts on every bare call. Resolving a conflict is the
# skill's judgment; the script stops at one and resumes with --continue.
#
# Modes:
#   --check      read only: the base, the stack under the branch, and the state
#                the skill asks from. Fetches, rewrites nothing.
#   (default)    fast-forward the local default branch to origin, rebase, push.
#   --continue   after the skill resolved a conflict: stage the files that were
#                conflicted (refusing any that still hold markers), continue the
#                rebase, and carry on with the rest of the plan.
#   --abort      abort the rebase and put every branch the plan already rebased
#                back where it was.
#
# The base follows prepare-review.sh's order: the open CR's target, else --onto,
# else the open CR the branch is stacked on, else the default branch.
# STACK_CHAIN walks down from there through each predecessor CR's own target
# until it reaches the default branch, so --cascade rebases the lowest branch
# onto origin/<default> and each one above onto the rebased one below it. A
# branch above replays only its own commits (`--onto <below> <fork>`, the fork
# being where it left the branch below before the cascade moved it), so the
# commits it shares with the branch below aren't replayed twice.
#
# A branch is force-pushed only where origin's copy matched it before the
# rebase, leased on that commit. Two pushes need the user's yes first, so a run
# reports them and exits 66 before anything moves: a branch whose CR is marked
# ready (a reviewer may have looked; --allow-ready), and a branch whose CR
# someone else authored (--allow-others), whose owner then gets a NOTIFY line. The fetch here moves origin/<branch>, so a bare
# --force-with-lease would take whatever it brought in as expected and overwrite
# it. A branch holding commits origin lacks is rebased and not pushed: those
# commits haven't been reviewed, and /anchor:commit pushes them. One where origin
# holds commits the checkout lacks is refused before anything is rewritten.
#
# Output lines (KEY=value, stdout). --check:
#   RESOLVED_VIA, FORGE, BRANCH, DEFAULT_BRANCH, ON_DEFAULT_BRANCH=<0|1>
#   BASE_BRANCH, BASE_SOURCE=<cr|onto|stacked|default>
#   STACK_CR_IID, STACK_CR_URL   the open CR whose branch BASE_BRANCH is
#   STACK_CHAIN=<b1,b2,...>      the branches under this one, lowest first; empty
#                                when the base is the default branch
#   STACK_LOOKUP_ERROR=<message> the open-CR listing failed
#   AHEAD, BEHIND                against origin/<BASE_BRANCH>
#   WORKTREE_CLEAN=<0|1>
#   REBASE_IN_PROGRESS=<0|1>     a git rebase is stopped in this checkout
#   PLAN_PENDING=<0|1>           and it is one this script started
#   CR_URL, CR_IID, CR_DRAFT, CR_AUTHOR   the branch's open CR, empty when none
#   STACK_BRANCH=<branch>:<cr>:<draft true|false>:<author>
#                                one line per STACK_CHAIN branch, lowest first
#   VIEWER=<login>               the forge user this run acts as; empty when no
#                                CR is involved
#   PUSH_STATE=<unpushed|match|ahead|behind|diverged>   HEAD against origin/<branch>
#   PUSHED_SHA=<sha>             origin/<branch>, empty on unpushed
# A run, --continue, and --abort:
#   DEFAULT_FF=<fast-forwarded|up-to-date|diverged|absent|refused>
#                                the local default branch against origin's
#                                (diverged: it holds commits origin lacks, and
#                                is left alone; refused: git refused the update)
#   REBASE_STATUS=<done|up-to-date|default-branch|conflict|aborted|needs-confirmation>
#   CONFIRM_READY=<branch>:<cr>  a branch to force-push whose CR is ready
#   CONFIRM_OTHERS=<branch>:<cr>:<author>   one whose CR someone else authored
#                                (both on exit 66; nothing has moved)
#   RESULT=<branch>:<rebased|unchanged>:<pushed|not-pushed-ahead|not-pushed-unpushed|rejected|->
#                                one line per branch, lowest first
#   CONFLICT_BRANCH, CONFLICT_FILES=<a,b>   on conflict
#   PUSH_ERROR=<message>         git's refusal, on a rejected push
#   NOTIFY=<branch>:<cr>:<author>   a branch force-pushed under someone else's CR
#   NEW_HEAD_SHA=<sha>           the checkout's branch after the run
#   REBASE_ERROR=<message>       on exit 1
#
# Exit codes:
#   0   done (any REBASE_STATUS but conflict)
#   1   REBASE_ERROR, or a rejected push
#   64  usage error
#   66  needs the user's yes (CONFIRM_*); re-run with --allow-ready / --allow-others
#   75  stopped on a conflict; resolve it, then --continue (or --abort)
#
# Usage:
#   rebase.sh --check [--onto <branch>] [--repo <path>]
#   rebase.sh [--cascade] [--allow-ready] [--allow-others] [--onto <branch>] [--repo <path>]
#   rebase.sh --continue [--repo <path>]
#   rebase.sh --abort [--repo <path>]

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stack.sh"

mode=run
cascade=0
allow_ready=0
allow_others=0
onto=""
CTX_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)    mode=check; shift ;;
    --continue) mode="continue"; shift ;;
    --abort)    mode=abort; shift ;;
    --cascade)  cascade=1; shift ;;
    --allow-ready)  allow_ready=1; shift ;;
    --allow-others) allow_others=1; shift ;;
    --onto)     onto="${2:?--onto needs a branch}"; onto="${onto#origin/}"; shift 2 ;;
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) echo "rebase.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

ctx_resolve_repo

# A conflict's --continue never stops in an editor.
export GIT_EDITOR=true

die() { echo "REBASE_ERROR=$*"; exit 1; }

git_dir=$(git rev-parse --git-dir)
plan="$git_dir/anchor/rebase-plan"

rebase_in_progress() { [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; }

current_branch() {
  local d
  for d in rebase-merge rebase-apply; do
    if [[ -r "$git_dir/$d/head-name" ]]; then
      sed 's#^refs/heads/##' "$git_dir/$d/head-name"
      return 0
    fi
  done
  git rev-parse --abbrev-ref HEAD
}

sha_of() { git rev-parse --verify --quiet "$1^{commit}" || true; }

# push_state <local ref> <branch>: the local ref against origin/<branch>.
push_state() {
  local local_sha remote_sha
  local_sha=$(sha_of "$1")
  remote_sha=$(sha_of "refs/remotes/origin/$2")
  if [[ -z "$remote_sha" ]]; then echo unpushed
  elif [[ "$remote_sha" == "$local_sha" ]]; then echo match
  elif git merge-base --is-ancestor "$remote_sha" "$local_sha"; then echo ahead
  elif git merge-base --is-ancestor "$local_sha" "$remote_sha"; then echo behind
  else echo diverged
  fi
}

# --- Context -------------------------------------------------------------------

origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
  *)            forge=none ;;
esac

branch=$(current_branch)
default_branch=$(anchor_default_branch) || default_branch=main
on_default=0
[[ "$branch" == "$default_branch" ]] && on_default=1

# --- The base and the stack under it ----------------------------------------------

resolve_base() {
  git fetch origin "$default_branch" >/dev/null 2>&1 || true
  git fetch origin "$branch" >/dev/null 2>&1 || true

  cr_url=""; cr_iid=""; cr_draft=""; cr_target=""; cr_author=""
  local json
  if [[ "$on_default" -eq 0 ]]; then
    case "$forge" in
      github)
        if json=$(gh pr view "$branch" --json url,number,isDraft,baseRefName,state,author 2>/dev/null) \
            && [[ "$(jq -r '.state // empty' <<<"$json")" == OPEN ]]; then
          cr_url=$(jq -r '.url // empty' <<<"$json")
          cr_iid=$(jq -r '.number // empty' <<<"$json")
          cr_draft=$(jq -r '.isDraft | values' <<<"$json")
          cr_target=$(jq -r '.baseRefName // empty' <<<"$json")
          cr_author=$(jq -r '.author.login // empty' <<<"$json")
        fi ;;
      gitlab)
        if json=$(glab mr view "$branch" --output json 2>/dev/null) \
            && [[ "$(jq -r '.state // empty' <<<"$json")" == opened ]]; then
          cr_url=$(jq -r '.web_url // empty' <<<"$json")
          cr_iid=$(jq -r '.iid // empty' <<<"$json")
          cr_draft=$(jq -r '.draft | values' <<<"$json")
          cr_target=$(jq -r '.target_branch // empty' <<<"$json")
          cr_author=$(jq -r '.author.username // empty' <<<"$json")
        fi ;;
    esac
  fi

  base_branch="$default_branch"
  base_source=default
  if [[ -n "$cr_target" ]]; then
    [[ -z "$onto" || "$onto" == "$cr_target" ]] \
      || die "$cr_url targets '$cr_target', not '$onto'; retarget it on the forge, or drop --onto"
    base_branch="$cr_target"
    base_source=cr
  elif [[ -n "$onto" ]]; then
    base_branch="$onto"
    base_source=onto
  fi

  stack_cr_iid=""; stack_cr_url=""; stack_lookup_error=""; open_crs=""
  # The listing finds a stacked base for a branch with no CR, and walks the
  # chain under any base that isn't the default branch.
  if [[ "$forge" != none && "$on_default" -eq 0 ]] \
      && [[ "$base_source" == default || "$base_branch" != "$default_branch" ]]; then
    local err line head
    err="$(anchor_tmpfile rebase-stack-err)"
    if open_crs=$(anchor_open_crs "$forge" 2>"$err"); then
      if [[ "$base_source" == default ]]; then
        line=$(anchor_stack_pick "$branch" "$default_branch" <<<"$open_crs")
        if [[ -n "$line" ]]; then
          IFS=$'\t' read -r head stack_cr_iid stack_cr_url <<<"$line"
          base_branch="$head"
          base_source=stacked
        fi
      elif [[ "$base_branch" != "$default_branch" ]]; then
        line=$(awk -F'\t' -v h="$base_branch" '$1 == h { print $3 "\t" $4; exit }' <<<"$open_crs")
        [[ -z "$line" ]] || IFS=$'\t' read -r stack_cr_iid stack_cr_url <<<"$line"
      fi
    else
      stack_lookup_error=$(head -1 "$err")
    fi
    rm -f "$err"
  fi

  if [[ "$base_branch" != "$default_branch" ]]; then
    git fetch origin "$base_branch" >/dev/null 2>&1 || true
    [[ -n "$(sha_of "refs/remotes/origin/$base_branch")" ]] \
      || die "origin has no branch '$base_branch' to rebase onto"
  fi

  # Walk down through each predecessor's own CR target to the default branch.
  stack_chain=()
  local cur="$base_branch" target n=0
  while [[ "$cur" != "$default_branch" && -z "$stack_lookup_error" ]]; do
    stack_chain=("$cur" ${stack_chain[@]+"${stack_chain[@]}"})
    n=$((n + 1))
    [[ "$n" -le 20 ]] || die "the stack under '$branch' is deeper than 20 branches, or loops"
    target=$(awk -F'\t' -v h="$cur" '$1 == h { print $5; exit }' <<<"$open_crs")
    [[ -n "$target" ]] || break
    git fetch origin "$target" >/dev/null 2>&1 || true
    cur="$target"
  done
  if [[ "$cur" != "$default_branch" && -z "$stack_lookup_error" && "${#stack_chain[@]}" -gt 0 ]]; then
    # The lowest branch has no open CR (merged, or never opened), so the chain
    # has no known base below it and can't cascade.
    chain_open=0
  else
    chain_open=1
  fi

  ahead=$(git rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null || echo 0)
  behind=$(git rev-list --count "HEAD..origin/${base_branch}" 2>/dev/null || echo 0)
}

# --- Fast-forward the local default branch -----------------------------------------

fast_forward_default() {
  local local_sha remote_sha
  local_sha=$(sha_of "refs/heads/$default_branch")
  remote_sha=$(sha_of "refs/remotes/origin/$default_branch")
  if [[ -z "$local_sha" || -z "$remote_sha" ]]; then
    default_ff=absent
  elif [[ "$local_sha" == "$remote_sha" ]]; then
    default_ff=up-to-date
  elif ! git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
    default_ff=diverged
  elif [[ "$on_default" -eq 1 ]]; then
    if git merge --ff-only --quiet "origin/$default_branch" >/dev/null 2>&1; then
      default_ff=fast-forwarded
    else
      default_ff=refused
    fi
  elif git branch -f "$default_branch" "origin/$default_branch" >/dev/null 2>&1; then
    default_ff=fast-forwarded
  else
    # git refuses to move a branch checked out in another worktree.
    default_ff=refused
  fi
  echo "DEFAULT_FF=$default_ff"
}

# --- Who owns what ------------------------------------------------------------------

# cr_info <branch>: "<cr>\t<draft>\t<author>" for the branch's open CR, empty
# fields when it has none.
cr_info() {
  if [[ "$1" == "$branch" ]]; then
    printf '%s\t%s\t%s\n' "$cr_iid" "$cr_draft" "$cr_author"
  else
    awk -F'\t' -v h="$1" 'BEGIN { found = 0 } $1 == h { print $3 "\t" $6 "\t" $7; found = 1; exit } END { if (!found) print "\t\t" }' <<<"$open_crs"
  fi
}

viewer=""
resolve_viewer() {
  [[ -z "$viewer" ]] || return 0
  case "$forge" in
    github) viewer=$(gh api user --jq .login 2>/dev/null) || die "gh api user failed, so whose CRs these are can't be told; check gh auth" ;;
    gitlab) viewer=$(glab api user 2>/dev/null | jq -r '.username // empty') || true
            [[ -n "$viewer" ]] || die "glab api user failed, so whose CRs these are can't be told; check glab auth" ;;
  esac
}

# --- The plan --------------------------------------------------------------------
#
# One line per branch, lowest first, tab-separated:
#   <branch> <onto ref> <fork|-> <tip before> <origin sha|-> <push: 1|0> <state> <done: 0|1>
#   <cr|-> <author|-> <mine: 1|0>
# plus a first line `top <branch>`.

write_plan() {
  local branches=() b i state onto_ref fork prev_tip origin_sha push
  if [[ "$cascade" -eq 1 ]]; then
    [[ "${#stack_chain[@]}" -gt 0 ]] || die "'$branch' isn't stacked on another open CR, so there's nothing to cascade"
    [[ "$chain_open" -eq 1 ]] || die "the lowest branch under '$branch' (${stack_chain[0]}) has no open CR, so the stack has no base to cascade from"
    branches=("${stack_chain[@]}" "$branch")
  else
    branches=("$branch")
  fi

  # Bring each branch below up to origin's copy before recording where it was.
  for b in "${branches[@]}"; do
    [[ "$b" != "$branch" ]] || continue
    git fetch origin "$b" >/dev/null 2>&1 || true
    [[ -n "$(sha_of "refs/remotes/origin/$b")" ]] || die "origin has no branch '$b'"
    if [[ -z "$(sha_of "refs/heads/$b")" ]]; then
      git branch --quiet --no-track "$b" "origin/$b"
    else
      state=$(push_state "refs/heads/$b" "$b")
      case "$state" in
        match) ;;
        behind) git branch -f "$b" "origin/$b" >/dev/null 2>&1 \
                  || die "git refused to fast-forward '$b' to origin's copy; is it checked out in another worktree?" ;;
        *) die "local '$b' holds commits origin's copy lacks ($state); push or drop them before cascading" ;;
      esac
    fi
  done

  state=$(push_state HEAD "$branch")
  case "$state" in
    behind|diverged) die "origin's '$branch' holds commits this checkout lacks ($state); a force-push would drop them" ;;
  esac

  local rows=() confirm=() cr draft author mine
  prev_tip=""
  i=0
  for b in "${branches[@]}"; do
    if [[ "$i" -eq 0 ]]; then
      if [[ "$cascade" -eq 1 ]]; then onto_ref="refs/remotes/origin/$default_branch"
      else onto_ref="refs/remotes/origin/$base_branch"; fi
      fork=-
    else
      onto_ref="refs/heads/${branches[$((i - 1))]}"
      fork=$(git merge-base "refs/heads/$b" "$prev_tip")
    fi
    origin_sha=$(sha_of "refs/remotes/origin/$b")
    if [[ "$b" == "$branch" ]]; then
      state=$(push_state HEAD "$branch")
    else
      state=match
    fi
    push=0
    [[ "$state" == match ]] && push=1
    cr=$(cut -f1 <<<"$(cr_info "$b")"); draft=$(cut -f2 <<<"$(cr_info "$b")"); author=$(cut -f3 <<<"$(cr_info "$b")")
    mine=1
    if [[ -n "$author" ]]; then
      resolve_viewer
      [[ "$author" == "$viewer" ]] || mine=0
    fi
    if [[ "$push" -eq 1 && -n "$cr" ]]; then
      [[ "$draft" != false || "$allow_ready" -eq 1 ]] || confirm+=("CONFIRM_READY=$b:$cr")
      [[ "$mine" -eq 1 || "$allow_others" -eq 1 ]] || confirm+=("CONFIRM_OTHERS=$b:$cr:$author")
    fi
    prev_tip=$(sha_of "refs/heads/$b")
    rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\t%s\t%s\t%s' "$b" "$onto_ref" "$fork" "$prev_tip" "${origin_sha:--}" "$push" "$state" "${cr:--}" "${author:--}" "$mine")")
    i=$((i + 1))
  done

  if [[ "${#confirm[@]}" -gt 0 ]]; then
    printf '%s\n' "${confirm[@]}"
    echo "REBASE_STATUS=needs-confirmation"
    exit 66
  fi

  mkdir -p "$(dirname "$plan")"
  { printf 'top\t%s\n' "$branch"; printf '%s\n' "${rows[@]}"; } > "$plan"
}

mark_done() {
  local tmp
  tmp="$(anchor_tmpfile rebase-plan)"
  awk -F'\t' -v OFS='\t' -v b="$1" '$1 == b { $8 = 1 } { print }' "$plan" > "$tmp"
  mv "$tmp" "$plan"
}

stop_on_conflict() {
  local b=$1 files
  files=$(git diff --name-only --diff-filter=U | paste -sd, -)
  echo "REBASE_STATUS=conflict"
  echo "CONFLICT_BRANCH=$b"
  echo "CONFLICT_FILES=$files"
  exit 75
}

# A rebase that stopped with files unmerged is a conflict for the skill; one that
# stopped any other way (a hook, a lock) is git's error to surface.
settle_failed_step() {
  local b=$1 err=$2
  if rebase_in_progress && [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    rm -f "$err"
    stop_on_conflict "$b"
  fi
  die "git rebase of '$b' stopped: $(grep -v '^hint:' "$err" | head -1); run --abort to put the branches back"
}

run_plan() {
  local b onto_ref fork tip origin_sha push state is_done err status
  while IFS=$'\t' read -r b onto_ref fork tip origin_sha push state is_done _; do
    [[ "$b" != top && "$is_done" == 0 ]] || continue
    err="$(anchor_tmpfile rebase-err)"
    status=0
    if [[ "$fork" == - ]]; then
      git rebase --quiet "$onto_ref" "$b" >/dev/null 2>"$err" || status=$?
    else
      git rebase --quiet --onto "$onto_ref" "$fork" "$b" >/dev/null 2>"$err" || status=$?
    fi
    if [[ "$status" -ne 0 ]]; then
      settle_failed_step "$b" "$err"
    fi
    rm -f "$err"
    mark_done "$b"
  done < "$plan"
}

finish() {
  local top b onto_ref fork tip origin_sha push state is_done cr author mine new result any_rebased=0 rejected=0 push_err
  top=$(awk -F'\t' '$1 == "top" { print $2 }' "$plan")
  git checkout --quiet "$top"
  while IFS=$'\t' read -r b onto_ref fork tip origin_sha push state is_done cr author mine; do
    [[ "$b" != top ]] || continue
    new=$(sha_of "refs/heads/$b")
    if [[ "$new" == "$tip" ]]; then
      echo "RESULT=$b:unchanged:-"
      continue
    fi
    any_rebased=1
    if [[ "$push" -eq 1 ]]; then
      push_err="$(anchor_tmpfile rebase-push-err)"
      if git push --quiet --force-with-lease="refs/heads/$b:$origin_sha" origin "refs/heads/$b:refs/heads/$b" 2>"$push_err"; then
        result=pushed
        [[ "$mine" -eq 1 ]] || echo "NOTIFY=$b:$cr:$author"
      else
        result=rejected
        rejected=1
        echo "PUSH_ERROR=$b: $(head -1 "$push_err")"
      fi
      rm -f "$push_err"
    else
      result="not-pushed-$state"
    fi
    echo "RESULT=$b:rebased:$result"
  done < "$plan"
  rm -f "$plan"
  if [[ "$any_rebased" -eq 1 ]]; then
    echo "REBASE_STATUS=done"
  else
    echo "REBASE_STATUS=up-to-date"
  fi
  echo "NEW_HEAD_SHA=$(git rev-parse HEAD)"
  [[ "$rejected" -eq 0 ]] || exit 1
}

# --- Modes -------------------------------------------------------------------------

case "$mode" in
  check)
    resolve_base
    worktree_clean=1
    [[ -n "$(git status --porcelain)" ]] && worktree_clean=0
    in_progress=0; rebase_in_progress && in_progress=1
    plan_pending=0; [[ -f "$plan" ]] && plan_pending=1
    pushed_sha=$(sha_of "refs/remotes/origin/$branch")
    echo "RESOLVED_VIA=$RESOLVED_VIA"
    echo "FORGE=$forge"
    echo "BRANCH=$branch"
    echo "DEFAULT_BRANCH=$default_branch"
    echo "ON_DEFAULT_BRANCH=$on_default"
    echo "BASE_BRANCH=$base_branch"
    echo "BASE_SOURCE=$base_source"
    echo "STACK_CR_IID=$stack_cr_iid"
    echo "STACK_CR_URL=$stack_cr_url"
    echo "STACK_CHAIN=$(IFS=,; echo "${stack_chain[*]+${stack_chain[*]}}")"
    echo "STACK_LOOKUP_ERROR=$stack_lookup_error"
    echo "AHEAD=$ahead"
    echo "BEHIND=$behind"
    echo "WORKTREE_CLEAN=$worktree_clean"
    echo "REBASE_IN_PROGRESS=$in_progress"
    echo "PLAN_PENDING=$plan_pending"
    echo "CR_URL=$cr_url"
    echo "CR_IID=$cr_iid"
    echo "CR_DRAFT=$cr_draft"
    echo "CR_AUTHOR=$cr_author"
    for b in ${stack_chain[@]+"${stack_chain[@]}"}; do
      echo "STACK_BRANCH=$b:$(cr_info "$b" | tr '\t' ':')"
    done
    if [[ -n "$cr_author" || "${#stack_chain[@]}" -gt 0 ]]; then
      resolve_viewer
    fi
    echo "VIEWER=$viewer"
    echo "PUSH_STATE=$(push_state HEAD "$branch")"
    echo "PUSHED_SHA=$pushed_sha"
    ;;

  run)
    [[ ! -f "$plan" ]] || die "a rebase this script started is unfinished; run --continue or --abort"
    ! rebase_in_progress || die "a rebase is already in progress; finish it with git rebase --continue or --abort"
    [[ -z "$(git status --porcelain)" ]] || die "the checkout has uncommitted changes; commit them before rebasing"
    resolve_base
    [[ -z "$stack_lookup_error" ]] || die "the open-CR listing failed, so the base can't be resolved: $stack_lookup_error"
    if [[ "$on_default" -eq 1 ]]; then
      fast_forward_default
      echo "REBASE_STATUS=default-branch"
      echo "NEW_HEAD_SHA=$(git rev-parse HEAD)"
      exit 0
    fi
    write_plan
    fast_forward_default
    run_plan
    finish
    ;;

  continue)
    [[ -f "$plan" ]] || die "no rebase this script started is unfinished"
    if rebase_in_progress; then
      b=$(current_branch)
      files=$(git diff --name-only --diff-filter=U)
      if [[ -n "$files" ]]; then
        marked=$(xargs grep -l -E '^(<<<<<<<|>>>>>>>)( |$)' <<<"$files" 2>/dev/null || true)
        [[ -z "$marked" ]] || die "conflict markers remain in: $(paste -sd, - <<<"$marked")"
        xargs git add -- <<<"$files"
      fi
      err="$(anchor_tmpfile rebase-err)"
      git rebase --continue >/dev/null 2>"$err" || settle_failed_step "$b" "$err"
      rm -f "$err"
      mark_done "$b"
    fi
    run_plan
    finish
    ;;

  abort)
    [[ -f "$plan" ]] || die "no rebase this script started is unfinished"
    if rebase_in_progress; then
      git rebase --abort
    fi
    top=$(awk -F'\t' '$1 == "top" { print $2 }' "$plan")
    git checkout --quiet "$top"
    while IFS=$'\t' read -r b _ _ tip _ _ _ is_done _; do
      [[ "$b" != top && "$b" != "$top" && "$is_done" == 1 ]] || continue
      git branch -f "$b" "$tip" >/dev/null
    done < "$plan"
    rm -f "$plan"
    echo "REBASE_STATUS=aborted"
    echo "NEW_HEAD_SHA=$(git rev-parse HEAD)"
    ;;
esac
