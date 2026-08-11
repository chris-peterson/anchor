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
#   - Open a draft when one already exists, or when --no-open is passed — those
#     resolve to the URL-free skip-deep-links path.
#   - Create the feature branch when HEAD is the default branch with work to
#     review — the script reports NEEDS_BRANCH and the skill branches first.
#   - Push. /anchor:commit now commits and pushes, so this script operates on an
#     already-pushed branch and never pushes. When commits are ahead of the
#     default branch with no CR yet and the branch isn't pushed, it reports
#     NEEDS_PUSH and the skill directs the user to /anchor:commit rather than
#     pushing here.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<worktree|repo|cwd>  worktree == ran in a --worktree checkout;
#                                repo == an explicit --repo checkout;
#                                cwd == inferred from the working directory
#   FORGE=<github|gitlab|none>
#   BRANCH=<current branch>
#   DEFAULT_BRANCH=<resolved default: origin/HEAD, else main, else master>
#   ON_DEFAULT_BRANCH=<0|1>      1 == HEAD is the default branch (no CR to open
#                                from — the skill branches first; see NEEDS_BRANCH)
#   AHEAD=<n>                    commits HEAD is ahead of the default branch
#   BEHIND=<n>                   commits HEAD is behind — >0 means run the rebase dialog
#   NEEDS_BRANCH=<0|1>           1 == on the default branch with work to review, so
#                                the skill must create a feature branch before a CR
#                                can be opened (paired with NEEDS_COMMIT when the
#                                work is still uncommitted)
#   NEEDS_COMMIT=<0|1>           1 == no reviewable commit exists yet (no CR and
#                                nothing ahead of the default branch, or uncommitted
#                                work on the default branch) — the skill chains into
#                                /anchor:commit before continuing
#   NEEDS_PUSH=<0|1>             1 == commit(s) ahead of the default branch, no CR
#                                yet, but the branch isn't pushed — the skill
#                                directs the user to /anchor:commit (which commits
#                                and pushes) rather than pushing here
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
#                                (baseline for the Step 4 review); empty when no CR
#   DESC_DRAFT_PATH=<path>       temp file the skill writes the drafted description
#                                to (the review's right-hand side)
#   TEMPLATE_PATH=<path>         the CR template to compose into, empty when the
#                                hierarchy holds none or the pick needs the author.
#                                Always absolute — the skill reads it from its own
#                                cwd, which under --repo/--worktree isn't this one
#   TEMPLATE_SOURCE=<local|project-settings|inherited|configured|ambiguous|none>
#                                which level answered. inherited == a GitLab
#                                parent group / the instance, or the owner's
#                                GitHub .github repo; configured ==
#                                anchor.crTemplateRepo; ambiguous == the level
#                                holds several and TEMPLATE_CANDIDATES carries them
#   TEMPLATE_CANDIDATES=<json>   [{name, path}] the author picks from when a level
#                                holds several templates and none is default.md;
#                                [] otherwise
#   DELETE_BRANCH_ON_MERGE=<true|false|unknown>
#                                will the resolved CR's source branch be deleted
#                                when it merges, without /anchor:merge passing
#                                --delete-branch? GitLab keeps this per MR
#                                (should_remove_source_branch, or
#                                force_remove_source_branch when the project
#                                forces it); GitHub has no per-PR field at all,
#                                so it reads the repo-wide deleteBranchOnMerge.
#                                unknown == no CR resolved, no forge, or the read
#                                failed — never collapsed into false, which the
#                                skill would act on
#   ANCHOR_CONFIG=<json>         {key: value} of anchor.* git config; {} when none
#   FILE_LINKS=<json>            {path: deep-link prefix} per changed file, from
#                                deep-links.sh — both forges; {} when no CR
#
# On an auth failure (or any failure) while opening the draft, it prints
# CR_CREATE_ERROR=<message> and exits non-zero so the skill surfaces it and asks
# the user to refresh credentials (the fail-fast-on-auth rule) rather than
# silently dropping to the URL-free path.
#
# Usage:
#   prepare-review.sh             # resolve the CR, or open a draft on the
#                                         # already-pushed branch; NEEDS_PUSH if unpushed
#   prepare-review.sh --no-open    # never auto-open; no CR -> skip-deep-links path
#   prepare-review.sh --repo <path>      # operate on a checkout other than the cwd repo
#   prepare-review.sh --worktree <path>  # operate in a flow-owned isolated worktree
#   prepare-review.sh --cr <iid|url>     # resolve a specific CR, not the current branch's
#
# --repo / --worktree cd into the target checkout so every git/gh/glab call
# below targets it (see scripts/lib/resolve-context.sh); the emitted RESOLVED_VIA
# reports whether the run used --worktree, --repo, or fell back to cwd. These are
# the fix for "target repo != session cwd": for a repo the session didn't start
# in, the skill sets up an isolated worktree first (scripts/worktree.sh) and
# passes it here as --worktree; --repo is the operate-directly case. Pair either
# with a checkout on the CR's branch when the CR you want isn't the current
# branch, or add --cr.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

auto_open=1
CTX_REPO=""
CTX_WORKTREE=""
cr_ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)  auto_open=0; shift ;;
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
    --cr)       cr_ref="${2:?--cr needs an iid or URL}"; shift 2 ;;
    *) echo "prepare-review.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# Retarget onto an explicit --repo checkout when given; otherwise stay in cwd
# (byte-for-byte today's behavior). Sets RESOLVED_VIA, emitted below.
ctx_resolve_repo

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
git fetch origin "$branch" >/dev/null 2>&1 || true
ahead=$(git rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || echo 0)
behind=$(git rev-list --count "HEAD..origin/${default_branch}" 2>/dev/null || echo 0)

local_head=$(git rev-parse HEAD)

# Is the branch pushed? origin/<branch> exists and HEAD is already on it.
# /anchor:commit does the push now; this script only opens the CR against it.
branch_pushed=0
if git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null; then
  [[ "$(git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 1)" -eq 0 ]] && branch_pushed=1
fi

# --- Resolve (or open) the CR ------------------------------------------------

cr_url=""; cr_iid=""; cr_draft=""; cr_head=""; cr_desc=""; cr_delete_branch=""
cr_preexisting=0; cr_created=0

# Pull a CR's url/iid/draft/headsha/description into the cr_* vars. Returns
# non-zero (leaving them empty) when no CR is open for the current branch.
resolve_cr() {
  # With --cr, view that specific CR (iid or URL) rather than the one the
  # current branch backs; without it, the branch's open CR as before.
  case "$forge" in
    gitlab)
      local json args=(--output json)
      [[ -n "$cr_ref" ]] && args=("$cr_ref" "${args[@]}")
      json=$(glab mr view "${args[@]}" 2>/dev/null) || return 1
      [[ -z "$json" ]] && return 1
      cr_url=$(jq -r '.web_url // empty' <<<"$json")
      [[ -z "$cr_url" ]] && return 1
      cr_iid=$(jq -r '.iid // empty' <<<"$json")
      cr_draft=$(jq -r '.draft // empty' <<<"$json")
      cr_head=$(jq -r '.sha // empty' <<<"$json")
      cr_desc=$(jq -r '.description // ""' <<<"$json")
      # Per-MR on GitLab: the create call's --remove-source-branch, or the
      # project forcing it for every MR.
      cr_delete_branch=$(jq -r '
        if (.should_remove_source_branch // false)
           or (.force_remove_source_branch // false)
        then "true" else "false" end' <<<"$json")
      ;;
    github)
      local json args=(--json "url,number,isDraft,headRefOid,body")
      [[ -n "$cr_ref" ]] && args=("$cr_ref" "${args[@]}")
      json=$(gh pr view "${args[@]}" 2>/dev/null) || return 1
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

needs_commit=0
needs_branch=0
needs_push=0

# Uncommitted work? (routes the on-default case below, and reused by the state
# check further down so we only shell out to `git status` once.)
tree_dirty=0
[[ -n "$(git status --porcelain)" ]] && tree_dirty=1

if [[ "$forge" != "none" && "$on_default" -eq 1 ]]; then
  # On the default branch there's no feature branch to open a CR from. Route
  # toward one whenever there's anything to review; the skill creates the branch,
  # then chains to /anchor:commit when the work isn't committed yet:
  #   uncommitted work            -> branch + commit  (NEEDS_BRANCH + NEEDS_COMMIT)
  #   unpushed commits on default -> move them to a branch (NEEDS_BRANCH)
  #   clean, nothing ahead        -> nothing to review (both stay 0)
  if [[ "$tree_dirty" -eq 1 ]]; then
    needs_branch=1
    needs_commit=1
  elif [[ "$ahead" -gt 0 ]]; then
    needs_branch=1
  fi
elif [[ "$forge" != "none" && "$on_default" -eq 0 ]]; then
  if resolve_cr; then
    cr_preexisting=1
  elif [[ "$ahead" -eq 0 ]]; then
    # No CR, and nothing committed ahead of the default branch. Opening a draft
    # here is what fails — `glab mr create` / `gh pr create` reject with "Could
    # not find any commits between origin/<default> and <branch>". The work is
    # finished but uncommitted (or the only commits are unpushed and zero ahead
    # of the default branch, e.g. on the default branch itself). Report the
    # condition so the skill chains into /anchor:commit instead of surfacing a
    # raw forge error.
    needs_commit=1
  elif [[ "$branch_pushed" -eq 0 ]]; then
    # Commit(s) ahead of the default branch, no CR, but the branch isn't pushed.
    # /anchor:commit commits and pushes; this script never pushes. Report
    # NEEDS_PUSH so the skill directs the user to /anchor:commit rather than
    # pushing an as-yet-unpushed branch here.
    needs_push=1
  elif [[ "$auto_open" -eq 1 ]]; then
    # The branch is pushed (by /anchor:commit) and no CR is open yet. Open a draft
    # against it — assigned to me — without pushing; the remote branch the create
    # call targets already exists. Branch deletion on merge is per-MR on GitLab
    # and repo-wide on GitHub, so only the GitLab create can set it; both report
    # the resulting state via DELETE_BRANCH_ON_MERGE below.
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
        # `gh pr create` has no branch-deletion flag — GitHub carries no per-PR
        # field for it.
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

# --- Will the source branch be deleted on merge? -----------------------------
#
# GitLab answers per MR (captured in resolve_cr). GitHub has no per-PR field, so
# the only standing answer is the repo-wide setting — which is why a PR anchor
# opens can't carry the preference the way an MR does, and why the skill names it
# when it's off. Scoped to a resolved CR on both forges: with no CR there's
# nothing for the skill to say.

delete_branch_on_merge=unknown
if [[ -n "$cr_url" ]]; then
  case "$forge" in
    github)
      repo_json=$(gh repo view --json deleteBranchOnMerge 2>/dev/null || true)
      setting=$(jq -r '.deleteBranchOnMerge | tostring' <<<"$repo_json" 2>/dev/null || true)
      case "$setting" in
        true|false) delete_branch_on_merge=$setting ;;
      esac
      ;;
    gitlab)
      case "$cr_delete_branch" in
        true|false) delete_branch_on_merge=$cr_delete_branch ;;
      esac
      ;;
  esac
fi

# --- Capture the current description (baseline for the Step 4 diff) ----------

current_desc_path=""
if [[ -n "$cr_url" ]]; then
  current_desc_path="$(anchor_tmpfile cr-desc-current)"
  printf '%s' "$cr_desc" > "$current_desc_path"
fi

# --- State check: local tree vs the CR head ----------------------------------

worktree_clean=1
[[ "$tree_dirty" -eq 1 ]] && worktree_clean=0

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
#
# Resolution walks from most specific to least, and the first level that yields
# a template wins — so a repo-local file still beats anything inherited:
#
#   GitLab   project setting -> repo-local files -> templates API -> crTemplateRepo
#   GitHub   repo-local files -> the owner's .github repo -> crTemplateRepo
#
# Neither forge needs its namespace walked. GitLab's
# `projects/:fullpath/templates/merge_requests` already answers with what the
# project may *use*, a parent group's and the instance's templates included;
# group templates live in one designated file-template project (a direct child
# of the group), never in each ancestor's own
# `.gitlab/merge_request_templates/`, so walking ancestors reads the wrong place
# and finds nothing. GitHub has no hierarchy to walk at all — one `.github`
# repo under the same owner, searched `.github/` -> root -> `docs/`.
#
# GitLab ranks its project-level "default description template" setting above
# both file sources, so that is read first and is the one level that has no file
# behind it. A level that 403s or answers nothing falls through to the next;
# only an empty hierarchy leaves TEMPLATE_PATH unset.
#
# Within a level the pick is deterministic rather than whatever the glob or the
# API returned first: `default.md` (case-insensitive), else the sole template,
# else TEMPLATE_CANDIDATES for the skill to put to the author. Several templates
# is a deliberate choice by the team, so the pick is the author's.

template_path=""
template_source=none
template_candidates='[]'
tpl_pick_path=""
tpl_pick_candidates='[]'
tpl_repo_cfg=$(git config --get anchor.crTemplateRepo 2>/dev/null || true)

# Drop the directory and the .md suffix so `Default.md` and
# `.github/PULL_REQUEST_TEMPLATE/default.md` both compare as `default`.
tpl_name() { local n="${1##*/}"; printf '%s' "${n%.md}"; }

# Choose one of the "name<TAB>path" lines on stdin, per the rule above.
tpl_pick() {
  local entries name path lower
  tpl_pick_path=""
  tpl_pick_candidates='[]'
  entries=$(cat)
  [[ -z "$entries" ]] && return 1
  if [[ "$(wc -l <<<"$entries")" -eq 1 ]]; then
    tpl_pick_path=${entries#*$'\t'}
    return 0
  fi
  while IFS=$'\t' read -r name path; do
    lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" == default ]] && { tpl_pick_path=$path; return 0; }
  done <<<"$entries"
  while IFS=$'\t' read -r name path; do
    tpl_pick_candidates=$(jq -c --arg n "$name" --arg p "$path" \
      '. + [{name: $n, path: $p}]' <<<"$tpl_pick_candidates")
  done <<<"$entries"
  return 0
}

# Read "name<TAB>path" lines from stdin and land the level's outcome in the
# template_* vars. Must be fed by redirection, never a pipe — the last stage of a
# pipeline runs in a subshell, where the assignments would be discarded.
tpl_resolve_from() {
  local source=$1
  tpl_pick || return 1
  if [[ -n "$tpl_pick_path" ]]; then
    template_path=$tpl_pick_path
    template_source=$source
    return 0
  fi
  if [[ "$tpl_pick_candidates" != '[]' ]]; then
    template_candidates=$tpl_pick_candidates
    template_source=ambiguous
    return 0
  fi
  return 1
}

tpl_unresolved() { [[ "$template_source" == none ]]; }

# Paths go out absolute. The script runs from inside the target checkout, but the
# skill reading TEMPLATE_PATH does not — under --repo / --worktree its cwd is a
# different repo entirely, where a repo-relative path resolves to nothing or, worse,
# to a same-named file.
tpl_local_gitlab() {
  local f
  for f in .gitlab/merge_request_templates/*.md; do
    [[ -e $f ]] || continue
    printf '%s\t%s\n' "$(tpl_name "$f")" "$PWD/$f"
  done
}

# GitHub honors a single template at three paths and a directory of them at
# three more, `.github/` first, then the root, then `docs/`. The first location
# that holds anything is the answer; anchor read only the two `.github` ones
# before.
tpl_local_github() {
  local f d out
  for f in .github/pull_request_template.md pull_request_template.md \
           docs/pull_request_template.md; do
    [[ -f $f ]] && { printf '%s\t%s\n' "$(tpl_name "$f")" "$PWD/$f"; return 0; }
  done
  for d in .github/PULL_REQUEST_TEMPLATE PULL_REQUEST_TEMPLATE \
           docs/PULL_REQUEST_TEMPLATE; do
    out=""
    for f in "$d"/*.md; do
      [[ -e $f ]] || continue
      out+="$(tpl_name "$f")"$'\t'"$PWD/$f"$'\n'
    done
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  done
  return 1
}

# Write a GitLab template's body to a temp file and echo the path. The name is a
# path segment, so it needs encoding — GitLab template names carry spaces
# ("Merge Request.md" is a common one).
tpl_fetch_gitlab() {
  local project=$1 name=$2 path encoded
  encoded=$(printf '%s' "$name" | jq -sRr @uri)
  path="$(anchor_tmpfile cr-template)"
  glab api "projects/${project}/templates/merge_requests/${encoded}" 2>/dev/null \
    | jq -r '.content // empty' > "$path" || return 1
  [[ -s "$path" ]] || return 1
  printf '%s' "$path"
}

tpl_entries_gitlab_api() {
  local project=$1 name path json
  json=$(glab api "projects/${project}/templates/merge_requests" 2>/dev/null) || return 1
  # The file-template project lists its own templates twice — once as the
  # project's, once as the group's — so dedupe before counting them.
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    path=$(tpl_fetch_gitlab "$project" "$name") || continue
    printf '%s\t%s\n' "$name" "$path"
  done < <(jq -r '[.[].name] | unique | .[]' <<<"$json" 2>/dev/null)
}

# `Accept: application/vnd.github.raw` returns the file body directly, which
# sidesteps decoding the API's base64 — GNU and BSD `base64` disagree on the
# decode flag.
tpl_fetch_github() {
  local repo=$1 file=$2 path
  path="$(anchor_tmpfile cr-template)"
  gh api "repos/${repo}/contents/${file}" \
    -H "Accept: application/vnd.github.raw" >"$path" 2>/dev/null || return 1
  [[ -s "$path" ]] || return 1
  printf '%s' "$path"
}

tpl_entries_github_repo() {
  local repo=$1 f d out path names
  gh api "repos/${repo}" >/dev/null 2>&1 || return 1
  for f in .github/pull_request_template.md pull_request_template.md \
           docs/pull_request_template.md; do
    path=$(tpl_fetch_github "$repo" "$f") \
      && { printf '%s\t%s\n' "$(tpl_name "$f")" "$path"; return 0; }
  done
  for d in .github/PULL_REQUEST_TEMPLATE PULL_REQUEST_TEMPLATE \
           docs/PULL_REQUEST_TEMPLATE; do
    names=$(gh api "repos/${repo}/contents/${d}" \
      --jq '.[] | select(.type == "file") | .name' 2>/dev/null) || continue
    out=""
    while IFS= read -r f; do
      [[ "$f" == *.md ]] || continue
      path=$(tpl_fetch_github "$repo" "${d}/${f}") || continue
      out+="$(tpl_name "$f")"$'\t'"$path"$'\n'
    done <<<"$names"
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  done
  return 1
}

case "$forge" in
  gitlab)
    settings_tpl=$(glab api "projects/:fullpath" 2>/dev/null \
      | jq -r '.merge_requests_template // empty' 2>/dev/null || true)
    if [[ -n "$settings_tpl" ]]; then
      template_path="$(anchor_tmpfile cr-template)"
      printf '%s' "$settings_tpl" > "$template_path"
      template_source="project-settings"
    fi
    if tpl_unresolved; then
      tpl_resolve_from local < <(tpl_local_gitlab) || true
    fi
    if tpl_unresolved; then
      tpl_resolve_from inherited < <(tpl_entries_gitlab_api :fullpath) || true
    fi
    if tpl_unresolved && [[ -n "$tpl_repo_cfg" ]]; then
      tpl_resolve_from configured \
        < <(tpl_entries_gitlab_api "$(printf '%s' "$tpl_repo_cfg" | jq -sRr @uri)") || true
    fi
    ;;
  github)
    if tpl_unresolved; then
      tpl_resolve_from local < <(tpl_local_github) || true
    fi
    if tpl_unresolved; then
      owner=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null || true)
      if [[ -n "$owner" ]]; then
        tpl_resolve_from inherited < <(tpl_entries_github_repo "${owner}/.github") || true
      fi
    fi
    if tpl_unresolved && [[ -n "$tpl_repo_cfg" ]]; then
      tpl_resolve_from configured < <(tpl_entries_github_repo "$tpl_repo_cfg") || true
    fi
    ;;
esac

# --- anchor.* config ----------------------------------------------------------

anchor_cfg='{}'
while read -r name value; do
  [[ -z "$name" ]] && continue
  anchor_cfg=$(jq -c --arg n "$name" --arg v "$value" '. + {($n): $v}' <<<"$anchor_cfg")
done < <(git config --get-regexp '^anchor\.' 2>/dev/null || true)

# --- Deep-link prefixes + draft path (both forges) ----------------------------

file_links='{}'
if [[ "$ahead" -gt 0 ]]; then
  file_links=$(bash "$(dirname "${BASH_SOURCE[0]}")/deep-links.sh" \
    --forge "$forge" --cr-url "$cr_url" --base "origin/${default_branch}" \
    | sed -n 's/^FILE_LINKS=//p')
fi

# The path Step 4 writes the drafted description to. Handed over here so drafting
# costs no separate mktemp call.
desc_draft_path="$(anchor_tmpfile cr-desc-draft)"

# --- Emit ---------------------------------------------------------------------

echo "RESOLVED_VIA=$RESOLVED_VIA"
echo "FORGE=$forge"
echo "BRANCH=$branch"
echo "DEFAULT_BRANCH=$default_branch"
echo "ON_DEFAULT_BRANCH=$on_default"
echo "AHEAD=$ahead"
echo "BEHIND=$behind"
echo "NEEDS_BRANCH=$needs_branch"
echo "NEEDS_COMMIT=$needs_commit"
echo "NEEDS_PUSH=$needs_push"
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
echo "DESC_DRAFT_PATH=$desc_draft_path"
echo "TEMPLATE_PATH=$template_path"
echo "TEMPLATE_SOURCE=$template_source"
echo "TEMPLATE_CANDIDATES=$template_candidates"
echo "DELETE_BRANCH_ON_MERGE=$delete_branch_on_merge"
echo "ANCHOR_CONFIG=$anchor_cfg"
echo "FILE_LINKS=$file_links"
