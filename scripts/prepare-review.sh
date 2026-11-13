#!/usr/bin/env bash
# Gather everything /prepare-review's Step 1 needs and perform the safe
# default-path actions, then print one KEY=value block on stdout so the skill
# acts on a single command's output — no per-step orchestration to narrate.
#
# Why a script (not skill prose): Step 1 is a string of deterministic recon and
# safe setup — detect the forge, resolve the CR if one is open, count the gap to
# the base branch, capture the current description, confirm local state
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
#   - Open the CR. Recon reports CR_PENDING=1 where one is creatable and leaves
#     it to `--open`, which the skill runs once the author has approved the
#     description (see below).
#   - Create the feature branch when HEAD is the default branch with work to
#     review — the script reports NEEDS_BRANCH and the skill branches first.
#   - Push. /anchor:commit now commits and pushes, so this script operates on an
#     already-pushed branch and never pushes. When commits are ahead of the
#     default branch with no CR yet and the branch isn't pushed, it reports
#     NEEDS_PUSH and the skill directs the user to /anchor:commit rather than
#     pushing here.
#
# Two phases, because the CR is opened last. The description's Review guide is
# drafted with `anchor:` placeholders (see deep-links.sh), which resolve to lines
# without a CR URL — so recon reports CR_PENDING and the author reviews a
# complete draft before anything is published under their name. `--open` then
# creates the draft CR with the approved body, and the skill expands the
# placeholders against the URL it returns.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>      repo == an explicit --repo checkout;
#                                cwd == inferred from the working directory
#   FORGE=<github|gitlab|none>
#   BRANCH=<current branch>
#   DEFAULT_BRANCH=<resolved default: origin/HEAD, else main, else master>
#   ON_DEFAULT_BRANCH=<0|1>      1 == HEAD is the default branch (no CR to open
#                                from — the skill branches first; see NEEDS_BRANCH)
#   BASE_BRANCH=<name>           the branch the CR targets, and what AHEAD, BEHIND,
#                                and the description's diff are measured against
#   BASE_SOURCE=<cr|onto|stacked|default>
#                                cr == the open CR's own target; onto == --onto;
#                                stacked == HEAD is stacked on another open CR's
#                                branch (STACK_CR_*), found by lib/stack.sh;
#                                default == none of those
#   STACK_CR_IID=<iid/number>    the open CR whose branch BASE_BRANCH is, on the
#   STACK_CR_URL=<web url>       onto and stacked sources; empty otherwise
#   STACK_LOOKUP_ERROR=<message> the open-CR listing that finds STACK_CR_* failed,
#                                so BASE_BRANCH may be the default branch when
#                                HEAD is stacked; empty when it ran
#   AHEAD=<n>                    commits HEAD is ahead of the base branch
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
#   NOTHING_TO_REVIEW=<0|1>      1 == a recognized forge, HEAD is the default
#                                branch, the tree is clean, and nothing is ahead:
#                                there is no branch to open a CR from and no work
#                                to put in one. The script exits 65 in this state
#                                (see Exit codes) — every other key is still
#                                emitted first so the caller can say why.
#   CR_PREEXISTING=<0|1>         a CR was already open before this run
#   CR_PENDING=<0|1>             1 == no CR is open, and the branch is in a state
#                                one can be opened from. The description is
#                                drafted and reviewed first; `--open` creates it
#                                afterward. 0 with no CR_URL is the URL-free
#                                skip-deep-links path (--no-open, or no forge)
#   CR_CREATED=<0|1>             `--open` opened a draft CR (always 0 on recon)
#   PRIOR_CR_IID=<iid/number>    a CR on this branch name that is not open, so it
#                                is not this run's target; empty when the branch
#                                carries none. Branch names get reused, so the
#                                skill names the one it passed over rather than
#                                leaving a fresh draft looking unexplained
#   PRIOR_CR_STATE=<state|>      that CR's state as the forge reports it —
#                                merged/closed/locked, or MERGED/CLOSED
#   CR_URL=<web url>             empty until a CR exists — on CR_PENDING as well
#                                as on the skip-deep-links path
#   CR_IID=<iid/number>          empty when no CR
#   CR_REFERENCE=<repo>#<n> | <repo>!<iid>   the CR as its forge writes it, the
#                                review's file name (`review-diff.sh --name`);
#                                empty when no CR
#   CR_DRAFT=<true|false|>       the CR's draft flag (empty when no CR)
#   CR_HEAD_SHA=<sha>            the CR head the reviewer sees (empty when no CR)
#   LOCAL_HEAD_SHA=<sha>         local HEAD
#   WORKTREE_CLEAN=<0|1>
#   STATE=<match|dirty|head-mismatch|dirty+head-mismatch>   drift vs the CR head
#   CURRENT_DESC_PATH=<path>     temp file holding the CR's current description
#                                (baseline for the Step 4 review). Always a path;
#                                the file is empty where no CR holds one yet
#   CR_REVIEW_STATUS_PATH=<path> the description's Review status section, taken
#                                out of CURRENT_DESC_PATH so the review compares
#                                prose with prose, with the rounds the local
#                                record holds for the branch's commits added
#                                where the section has none; `--write` puts it
#                                back. Always a path; the file is empty where
#                                there is neither
#   DESC_DRAFT_PATH=<path>       temp file the skill writes the drafted description
#                                to (the review's right-hand side)
#   TEMPLATE_PATH=<path>         the CR template to compose into, empty when the
#                                hierarchy holds none or the pick needs the author.
#                                Always absolute — the skill reads it from its own
#                                cwd, which under --repo isn't this one
#   TEMPLATE_SOURCE=<local|project-settings|inherited|configured|ambiguous|none>
#                                which level answered. inherited == a GitLab
#                                parent group / the instance, or the owner's
#                                GitHub .github repo; configured ==
#                                anchor.cr.templateRepo; ambiguous == the level
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
#
# On an auth failure (or any failure) while opening the draft, it prints
# CR_CREATE_ERROR=<message> and exits non-zero so the skill surfaces it and asks
# the user to refresh credentials (the fail-fast-on-auth rule) rather than
# silently dropping to the URL-free path. A review record it can't read (the
# CR's Review status section, or the local record), an --onto branch origin
# doesn't have, or an --onto that disagrees with the open CR's target prints
# PREPARE_ERROR=<message> on stderr and exits 1.
#
# Exit codes:
#   0   the block is a state the flow continues from
#   64  usage error (unknown argument)
#   65  NOTHING_TO_REVIEW — the dead end above. Its own code, not 1, so the skill
#       can tell "this flow does not apply here" from "something broke". A caller
#       that reaches this state has nothing to open a CR against, so continuing
#       past it means the CR step was silently dropped from whatever chain asked
#       for it; the non-zero status is what makes that visible instead of leaving
#       it to the reader of a KEY=value block.
#   1   an operational failure (CR_CREATE_ERROR, PREPARE_ERROR)
#
# Usage:
#   prepare-review.sh                     # recon: resolve the CR, or report CR_PENDING
#   prepare-review.sh --no-open           # no CR will be opened -> skip-deep-links path
#   prepare-review.sh --repo <path>       # operate on a checkout other than the cwd repo
#   prepare-review.sh --cr <iid|url>      # resolve a specific CR, not the current branch's
#   prepare-review.sh --onto <branch>     # target <branch> rather than the default
#                                         # branch or a detected predecessor; pass
#                                         # it to --open as well
#   prepare-review.sh --open --title <t> --body-file <path>
#                                         # open the draft CR with the approved
#                                         # description; emits the CR keys only
#   prepare-review.sh --write --body-file <path> [--status-section <path>] [--cr <iid>]
#                                         # write the approved description to the
#                                         # CR with its Review status section put
#                                         # back, after saving the one it replaces;
#                                         # refuses a CR whose source branch isn't
#                                         # the checkout's. Emits CR_WRITTEN,
#                                         # STATUS_CARRIED; the backup is silent
#
# --repo cds into the target checkout so every git/gh/glab call below targets it
# (see scripts/lib/resolve-context.sh); the emitted RESOLVED_VIA reports whether
# the run used --repo or fell back to cwd. It is the fix for "target repo !=
# session cwd". Pair it with a checkout on the CR's branch when the CR you want
# isn't the current branch, or add --cr.

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/anchor-config.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/anchor-config.sh"
# shellcheck source=lib/review-status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-status.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"
# shellcheck source=lib/stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stack.sh"

will_open=1
do_open=0
do_write=0
open_title=""
open_body=""
status_section=""
CTX_REPO=""
cr_ref=""
onto=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)   will_open=0; shift ;;
    --open)      do_open=1; shift ;;
    --write)     do_write=1; shift ;;
    --status-section) status_section="${2:?--status-section needs a path}"; shift 2 ;;
    --title)     open_title="${2:?--title needs a value}"; shift 2 ;;
    --body-file) open_body="${2:?--body-file needs a path}"; shift 2 ;;
    --repo)      CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --cr)        cr_ref="${2:?--cr needs an iid or URL}"; shift 2 ;;
    --onto)      onto="${2:?--onto needs a branch}"; onto="${onto#origin/}"; shift 2 ;;
    *) echo "prepare-review.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ "$do_open" -eq 1 ]]; then
  [[ -n "$open_title" ]] || { echo "prepare-review.sh: --open needs --title" >&2; exit 64; }
  [[ -r "$open_body" ]] || { echo "prepare-review.sh: --open needs a readable --body-file" >&2; exit 64; }
fi
if [[ "$do_write" -eq 1 ]]; then
  [[ "$do_open" -eq 0 ]] || { echo "prepare-review.sh: --open and --write are separate calls" >&2; exit 64; }
  [[ -r "$open_body" ]] || { echo "prepare-review.sh: --write needs a readable --body-file" >&2; exit 64; }
  [[ -z "$status_section" || -r "$status_section" ]] \
    || { echo "prepare-review.sh: --status-section must be a readable file" >&2; exit 64; }
fi

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

default_branch=$(anchor_default_branch) || default_branch=main

on_default=0
[[ "$branch" == "$default_branch" ]] && on_default=1

git fetch origin "$default_branch" >/dev/null 2>&1 || true
git fetch origin "$branch" >/dev/null 2>&1 || true

local_head=$(git rev-parse HEAD)

# Is the branch pushed? origin/<branch> exists and HEAD is already on it.
# /anchor:commit does the push now; this script only opens the CR against it.
branch_pushed=0
if git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null; then
  [[ "$(git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 1)" -eq 0 ]] && branch_pushed=1
fi

# --- Resolve (or open) the CR ------------------------------------------------

cr_url=""; cr_iid=""; cr_draft=""; cr_head=""; cr_branch=""; cr_target=""; cr_desc=""; cr_delete_branch=""; cr_title=""
cr_preexisting=0; cr_created=0; cr_pending=0
prior_cr_iid=""; prior_cr_state=""

# Pull a CR's url/iid/draft/headsha/description into the cr_* vars. Returns
# non-zero (leaving them empty) when no CR is open for the current branch.
#
# Only an open CR counts on the branch-inferred path. Neither CLI filters its
# branch lookup by state, so a branch name that has been used before resolves to
# whatever CR used it last — a merged one adopted as this run's target skips the
# auto-open below, and the description then has no open CR to land on. The state
# is read off the result the lookup already returned, so this costs no extra
# call, and it is checked before any cr_* var is assigned so a rejected CR leaves
# them empty as the contract above promises. An explicit --cr names one specific
# CR, so that path resolves whatever was asked for whatever its state.
resolve_cr() {
  # With --cr, view that specific CR (iid or URL) rather than the one the
  # current branch backs; without it, the branch's open CR as before.
  case "$forge" in
    gitlab)
      local json args=(--output json)
      [[ -n "$cr_ref" ]] && args=("$cr_ref" "${args[@]}")
      json=$(glab mr view "${args[@]}" 2>/dev/null) || return 1
      [[ -z "$json" ]] && return 1
      local mr_state
      mr_state=$(jq -r '.state // empty' <<<"$json")
      if [[ -z "$cr_ref" && "$mr_state" != "opened" ]]; then
        prior_cr_state="$mr_state"
        prior_cr_iid=$(jq -r '.iid // empty' <<<"$json")
        return 1
      fi
      cr_url=$(jq -r '.web_url // empty' <<<"$json")
      [[ -z "$cr_url" ]] && return 1
      cr_iid=$(jq -r '.iid // empty' <<<"$json")
      cr_draft=$(jq -r '.draft | values' <<<"$json")
      cr_head=$(jq -r '.sha // empty' <<<"$json")
      cr_branch=$(jq -r '.source_branch // empty' <<<"$json")
      cr_target=$(jq -r '.target_branch // empty' <<<"$json")
      cr_desc=$(jq -r '.description // ""' <<<"$json")
      cr_title=$(jq -r '.title // ""' <<<"$json")
      # Per-MR on GitLab: the create call's --remove-source-branch, or the
      # project forcing it for every MR.
      cr_delete_branch=$(jq -r '
        if (.should_remove_source_branch // false)
           or (.force_remove_source_branch // false)
        then "true" else "false" end' <<<"$json")
      ;;
    github)
      local json args=(--json "url,number,isDraft,headRefOid,headRefName,baseRefName,body,state,title")
      [[ -n "$cr_ref" ]] && args=("$cr_ref" "${args[@]}")
      json=$(gh pr view "${args[@]}" 2>/dev/null) || return 1
      [[ -z "$json" ]] && return 1
      local pr_state
      pr_state=$(jq -r '.state // empty' <<<"$json")
      if [[ -z "$cr_ref" && "$pr_state" != "OPEN" ]]; then
        prior_cr_state="$pr_state"
        prior_cr_iid=$(jq -r '.number // empty' <<<"$json")
        return 1
      fi
      cr_url=$(jq -r '.url // empty' <<<"$json")
      [[ -z "$cr_url" ]] && return 1
      cr_iid=$(jq -r '.number // empty' <<<"$json")
      cr_draft=$(jq -r '.isDraft | values' <<<"$json")
      cr_head=$(jq -r '.headRefOid // empty' <<<"$json")
      cr_branch=$(jq -r '.headRefName // empty' <<<"$json")
      cr_target=$(jq -r '.baseRefName // empty' <<<"$json")
      cr_desc=$(jq -r '.body // ""' <<<"$json")
      cr_title=$(jq -r '.title // ""' <<<"$json")
      ;;
    *) return 1 ;;
  esac
}

# --- Will the source branch be deleted on merge? -----------------------------
#
# GitLab answers per MR (captured in resolve_cr). GitHub has no per-PR field, so
# the only standing answer is the repo-wide setting — which is why a PR anchor
# opens can't carry the preference the way an MR does, and why the skill names it
# when it's off. Scoped to a resolved CR on both forges: with no CR there's
# nothing for the skill to say.
delete_branch_on_merge=unknown
read_delete_branch_on_merge() {
  delete_branch_on_merge=unknown
  [[ -n "$cr_url" ]] || return 0
  local repo_json setting
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
}

# --- --open: create the draft CR with the approved description ---------------
#
# The last step of the flow, not the first. The body is the text the author
# signed off on, placeholders and all; the skill expands those against the URL
# this returns. Landing the approved prose first means a failed expansion leaves
# a CR carrying what the author wrote rather than an empty one.
if [[ "$do_open" -eq 1 ]]; then
  if [[ "$forge" == "none" ]]; then
    echo "CR_CREATE_ERROR=origin is not a recognized forge, so there is no CR to open"
    exit 1
  fi
  if resolve_cr; then
    echo "CR_CREATE_ERROR=a CR is already open on this branch ($cr_url) — write to it instead of opening another"
    exit 1
  fi
  open_base="${onto:-$default_branch}"
  case "$forge" in
    gitlab)
      username=$(glab api user 2>/dev/null | jq -r '.username // empty' || true)
      if ! create_err=$(glab mr create --draft --yes \
            --title "$open_title" --description "$(cat "$open_body")" \
            --target-branch "$open_base" --remove-source-branch \
            --assignee "$username" 2>&1); then
        echo "CR_CREATE_ERROR=glab mr create failed: $create_err"
        exit 1
      fi
      ;;
    github)
      # `gh pr create` has no branch-deletion flag — GitHub carries no per-PR
      # field for it, only the repo-wide setting read below.
      if ! create_err=$(gh pr create --draft --assignee @me --base "$open_base" \
            --title "$open_title" --body-file "$open_body" 2>&1); then
        echo "CR_CREATE_ERROR=gh pr create failed: $create_err"
        exit 1
      fi
      ;;
  esac
  # The create reported success, so the CR exists. If the re-resolve fails
  # (forge create→read lag), surface it rather than going quiet — the skill has
  # an approved description in hand and nowhere recorded to expand it against.
  if ! resolve_cr; then
    echo "CR_CREATE_ERROR=opened the draft CR but could not resolve it back (forge lag?) — re-run prepare-review"
    exit 1
  fi
  read_delete_branch_on_merge
  echo "RESOLVED_VIA=$RESOLVED_VIA"
  echo "FORGE=$forge"
  echo "CR_CREATED=1"
  echo "CR_URL=$cr_url"
  echo "CR_IID=$cr_iid"
  echo "CR_DRAFT=$cr_draft"
  echo "DEFAULT_BRANCH=$default_branch"
  echo "BASE_BRANCH=$open_base"
  echo "CR_TITLE=$open_title"
  echo "DELETE_BRANCH_ON_MERGE=$delete_branch_on_merge"
  # Announce the CR to whoever in the suite is listening. This is the only path
  # that opens one, so it is the only path holding that fact. The announcement
  # repeats what the block above says because a subscriber reads a whole tool
  # output and cannot tell which run a loose `CR_URL=` belonged to.
  #
  # A run announces `cr.created` or `cr.updated`, never both: setting up a CR
  # this run just opened is not an update to it. That is why the skill's
  # `cr.updated` step reads `CR_CREATED` before firing.
  "$(dirname "${BASH_SOURCE[0]}")/announce.sh" cr.created \
    "uri=$cr_url" "title=$open_title"
  exit 0
fi

# --- --write: land the approved description on the CR -------------------------
#
# The draft the author approved is prose alone; the Review status section goes
# back on here, into a copy, so the reviewed file never changes after its review.
# The section joins the one the CR holds now, read fresh, so a round recorded
# since recon survives, and the CR's own rounds win where both have a commit.
# The write runs in this script so one allow rule covers it: the section is
# anchor's record, written without an approval of its text (CONFIRM-17).
if [[ "$do_write" -eq 1 ]]; then
  if [[ "$forge" == "none" ]]; then
    echo "CR_WRITE_ERROR=origin is not a recognized forge, so there is no CR to write to"
    exit 1
  fi
  if ! resolve_cr; then
    echo "CR_WRITE_ERROR=no open CR resolved to write to; pass --cr <iid>"
    exit 1
  fi
  # CR numbers are shared across a project, so a --cr taken from anywhere but
  # this branch's own CR names someone else's, and the forge accepts the write
  # whenever the user can edit it.
  if [[ "$cr_branch" != "$branch" ]]; then
    echo "CR_WRITE_ERROR=$cr_url is from branch '${cr_branch:-<unknown>}', not '$branch'; refusing to write another branch's CR"
    exit 1
  fi
  backup_path=$(anchor_backup_path "cr-$cr_iid" md)
  printf '%s' "$cr_desc" > "$backup_path"
  fresh_desc="$(anchor_tmpfile cr-desc-fresh md)"
  printf '%s\n' "$cr_desc" > "$fresh_desc"
  fresh_rounds=$(review_status_data "$fresh_desc") \
    || { echo "PREPARE_ERROR=the CR's Review status section holds data that isn't JSON; fix or delete its opening comment" >&2; exit 1; }
  carried_rounds='{}'
  if [[ -n "$status_section" ]]; then
    carried_rounds=$(review_status_data "$status_section") \
      || { echo "PREPARE_ERROR=--status-section holds data that isn't JSON" >&2; exit 1; }
  fi
  rounds=$(jq -c --argjson cr "$fresh_rounds" '. + $cr' <<<"$carried_rounds")
  write_body="$(anchor_tmpfile cr-desc-write md)"
  status_carried=0
  if [[ "$rounds" != '{}' ]]; then
    section_file="$(anchor_tmpfile cr-review-status-write md)"
    review_status_section "$rounds" > "$section_file"
    review_status_splice "$open_body" "$section_file" > "$write_body"
    status_carried=1
  else
    cp "$open_body" "$write_body"
  fi
  write_err=$(anchor_cr_write_description "$forge" "$cr_iid" "$write_body") \
    || { echo "CR_WRITE_ERROR=the description write failed: $write_err"; exit 1; }
  echo "RESOLVED_VIA=$RESOLVED_VIA"
  echo "FORGE=$forge"
  echo "CR_URL=$cr_url"
  echo "CR_IID=$cr_iid"
  echo "CR_WRITTEN=1"
  echo "STATUS_CARRIED=$status_carried"
  exit 0
fi

# --- The base branch, and the gap to it ----------------------------------------
#
# The open CR's own target wins, since the forge already measures the CR against
# it. Without one, --onto names it; failing that, the open CR this branch is
# stacked on (lib/stack.sh); failing that, the default branch.

cr_resolved=0
if [[ "$forge" != "none" && "$on_default" -eq 0 ]] && resolve_cr; then
  cr_resolved=1
fi

base_branch="$default_branch"
base_source=default
stack_cr_iid=""; stack_cr_url=""; stack_lookup_error=""
if [[ "$cr_resolved" -eq 1 && -n "$cr_target" ]]; then
  if [[ -n "$onto" && "$onto" != "$cr_target" ]]; then
    echo "PREPARE_ERROR=$cr_url already targets '$cr_target', not '$onto'; move it with /anchor:stack on $onto, or drop --onto" >&2
    exit 1
  fi
  base_branch="$cr_target"
  base_source=cr
elif [[ -n "$onto" ]]; then
  base_branch="$onto"
  base_source=onto
fi

if [[ "$forge" != "none" && "$on_default" -eq 0 && "$cr_resolved" -eq 0 && "$onto" != "$default_branch" ]]; then
  stack_err="$(anchor_tmpfile stack-lookup-err)"
  if open_crs=$(anchor_open_crs "$forge" 2>"$stack_err"); then
    if [[ -n "$onto" ]]; then
      stack_line=$(awk -F'\t' -v h="$onto" '$1 == h { print $1 "\t" $3 "\t" $4; exit }' <<<"$open_crs")
    else
      stack_line=$(anchor_stack_pick "$branch" "$default_branch" <<<"$open_crs")
    fi
    if [[ -n "$stack_line" ]]; then
      IFS=$'\t' read -r stack_head stack_cr_iid stack_cr_url <<<"$stack_line"
      if [[ "$base_source" == default ]]; then
        base_branch="$stack_head"
        base_source=stacked
      fi
    fi
  else
    stack_lookup_error=$(head -1 "$stack_err")
  fi
  rm -f "$stack_err"
fi

if [[ "$base_branch" != "$default_branch" ]]; then
  git fetch origin "$base_branch" >/dev/null 2>&1 || true
  if ! git rev-parse --verify --quiet "refs/remotes/origin/${base_branch}" >/dev/null; then
    echo "PREPARE_ERROR=origin has no branch '$base_branch' to target" >&2
    exit 1
  fi
fi

ahead=$(git rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null || echo 0)
behind=$(git rev-list --count "HEAD..origin/${base_branch}" 2>/dev/null || echo 0)

needs_commit=0
needs_branch=0
needs_push=0
nothing_to_review=0

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
  else
    # Nothing to branch from and nothing to put in a CR. Unlike the two above,
    # this state has no route forward — reported as a key and exited on below.
    nothing_to_review=1
  fi
elif [[ "$forge" != "none" && "$on_default" -eq 0 ]]; then
  if [[ "$cr_resolved" -eq 1 ]]; then
    cr_preexisting=1
  elif [[ "$ahead" -eq 0 ]]; then
    # No CR, and nothing committed ahead of the base branch. Opening a draft
    # here is what fails — `glab mr create` / `gh pr create` reject with "Could
    # not find any commits between origin/<base> and <branch>". The work is
    # finished but uncommitted (or the only commits are unpushed and zero ahead
    # of the default branch, e.g. on the default branch itself). Report the
    # condition so the skill chains into /anchor:commit instead of surfacing a
    # raw forge error.
    needs_commit=1
  elif [[ "$branch_pushed" -eq 0 ]]; then
    # Commit(s) ahead of the base branch, no CR, but the branch isn't pushed.
    # /anchor:commit commits and pushes; this script never pushes. Report
    # NEEDS_PUSH so the skill directs the user to /anchor:commit rather than
    # pushing an as-yet-unpushed branch here.
    needs_push=1
  elif [[ "$will_open" -eq 1 ]]; then
    # The branch is pushed (by /anchor:commit) and no CR is open yet, so one can
    # be. It is opened by `--open` once the author has approved the description,
    # not here: the Review guide's deep links are drafted as placeholders that
    # resolve without a CR URL, so nothing has to exist on the forge for the
    # draft to be complete and reviewable.
    cr_pending=1
  fi
fi

read_delete_branch_on_merge

# --- Capture the current description (baseline for the Step 4 diff) ----------

# Always a file, empty where there is no CR to read one from — which is the usual
# case now that the CR is opened last. The review dispatcher takes a pair of
# paths, so an empty string here is a usage error rather than an empty left-hand
# side, and the review the skill is about to open never launches.
current_desc_path="$(anchor_tmpfile cr-desc-current)"
review_status_path="$(anchor_tmpfile cr-review-status)"
: > "$current_desc_path"
: > "$review_status_path"
if [[ -n "$cr_url" ]]; then
  printf '%s\n' "$cr_desc" > "$current_desc_path.full"
  review_status_strip "$current_desc_path.full" "$review_status_path" > "$current_desc_path"
  rm -f "$current_desc_path.full"
fi

# Rounds the branch's commits had before the CR existed are in the local record
# (scripts/lib/review-status.sh). They join the section where it has none for a
# commit, so the CR's first review starts where those rounds stopped.
if [[ "$on_default" -eq 0 ]] && git rev-parse --verify --quiet "origin/${base_branch}" >/dev/null; then
  branch_base=$(git merge-base "origin/${base_branch}" HEAD)
  local_data=$(review_status_local_data) \
    || { echo "PREPARE_ERROR=the local review record at $(review_status_local_path) isn't JSON; fix or delete it" >&2; exit 1; }
  local_rounds=$(review_status_pick "$local_data" "$branch_base" HEAD)
  cr_rounds=$(review_status_data "$review_status_path") \
    || { echo "PREPARE_ERROR=the CR's Review status section holds data that isn't JSON; fix or delete its opening comment" >&2; exit 1; }
  if jq -e --argjson cr "$cr_rounds" 'keys - ($cr | keys) | length > 0' <<<"$local_rounds" >/dev/null; then
    review_status_section "$(jq -c --argjson cr "$cr_rounds" '. + $cr' <<<"$local_rounds")" > "$review_status_path"
  fi
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
#   GitLab   project setting -> repo-local files -> templates API -> cr.templateRepo
#   GitHub   repo-local files -> the owner's .github repo -> cr.templateRepo
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
tpl_repo_cfg=$(git config --get anchor.cr.templateRepo 2>/dev/null || true)

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
# skill reading TEMPLATE_PATH does not — under --repo its cwd is a different repo
# entirely, where a repo-relative path resolves to nothing or, worse, to a
# same-named file.
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

anchor_cfg=$(anchor_config_json)
anchor_config_warnings >&2

# --- Draft path ---------------------------------------------------------------

# The path Step 4 writes the drafted description to. Handed over here so drafting
# costs no separate mktemp call.
desc_draft_path="$(anchor_tmpfile cr-desc-draft)"

cr_reference=""
[[ -z "$cr_iid" ]] || cr_reference=$(anchor_cr_reference "$cr_url" "$cr_iid")

# --- Emit ---------------------------------------------------------------------

echo "RESOLVED_VIA=$RESOLVED_VIA"
echo "FORGE=$forge"
echo "BRANCH=$branch"
echo "DEFAULT_BRANCH=$default_branch"
echo "ON_DEFAULT_BRANCH=$on_default"
echo "BASE_BRANCH=$base_branch"
echo "BASE_SOURCE=$base_source"
echo "STACK_CR_IID=$stack_cr_iid"
echo "STACK_CR_URL=$stack_cr_url"
echo "STACK_LOOKUP_ERROR=$stack_lookup_error"
echo "AHEAD=$ahead"
echo "BEHIND=$behind"
echo "NEEDS_BRANCH=$needs_branch"
echo "NEEDS_COMMIT=$needs_commit"
echo "NEEDS_PUSH=$needs_push"
echo "NOTHING_TO_REVIEW=$nothing_to_review"
echo "CR_PREEXISTING=$cr_preexisting"
echo "CR_PENDING=$cr_pending"
echo "CR_CREATED=$cr_created"
echo "PRIOR_CR_IID=$prior_cr_iid"
echo "PRIOR_CR_STATE=$prior_cr_state"
echo "CR_URL=$cr_url"
echo "CR_IID=$cr_iid"
echo "CR_REFERENCE=$cr_reference"
echo "CR_DRAFT=$cr_draft"
echo "CR_TITLE=$cr_title"
echo "CR_HEAD_SHA=$cr_head"
echo "LOCAL_HEAD_SHA=$local_head"
echo "WORKTREE_CLEAN=$worktree_clean"
echo "STATE=$state"
echo "CURRENT_DESC_PATH=$current_desc_path"
echo "CR_REVIEW_STATUS_PATH=$review_status_path"
echo "DESC_DRAFT_PATH=$desc_draft_path"
echo "TEMPLATE_PATH=$template_path"
echo "TEMPLATE_SOURCE=$template_source"
echo "TEMPLATE_CANDIDATES=$template_candidates"
echo "DELETE_BRANCH_ON_MERGE=$delete_branch_on_merge"
echo "ANCHOR_CONFIG=$anchor_cfg"

# Exit last, so the block above is complete: the caller reports the dead end from
# the same keys it reads on every other path, and only the status differs.
if [[ "$nothing_to_review" -eq 1 ]]; then
  echo "prepare-review.sh: nothing to review — $branch is the default branch, the tree is clean, and nothing is ahead of it. There is no branch to open a change request from." >&2
  exit 65
fi
