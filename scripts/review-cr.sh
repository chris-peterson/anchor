#!/usr/bin/env bash
# Gather everything /anchor:review needs about someone else's change request and
# print one KEY=value block on stdout, so the skill acts on a single command's
# output rather than orchestrating six forge calls it would narrate between.
#
# Why a script (not skill prose): resolving a CR from a number, a URL, or a
# branch; reading its description; fetching its head into the local checkout;
# and pinning the SHAs a line-anchored comment has to carry are all
# deterministic. What the diff *means* is the model's half and stays in the
# SKILL.md.
#
# The head SHA is captured here, at fetch time, and re-checked by
# review-post.sh before anything posts. A CR whose head moves mid-review would
# otherwise anchor comments to lines that no longer exist.
#
# The diff is produced from refs fetched into the local checkout rather than
# from `gh pr diff` / `glab mr diff`, because the same range then feeds
# review-diff.sh — the reviewer sees the changes in a diff viewer, and what they
# annotate is the same text this block describes. Both forges publish the CR
# head under a well-known ref namespace, so this works for a fork-sourced CR and
# needs no branch checkout:
#   GitHub  refs/pull/<number>/head
#   GitLab  refs/merge-requests/<iid>/head
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>      which checkout the run operated in
#   FORGE=<github|gitlab>        picks the CLI for the rest of the flow
#   HOST=<host>                  e.g. gitlab.example.com (glab --hostname)
#   PROJECT=<owner/name>         full project path after the host, any depth
#   HAS_CR=<0|1>                 0 == run with no argument on a branch that has
#                                never had a CR: the review is of the branch's
#                                commits ahead of BASE_BRANCH. Then
#                                CR_IID, CR_URL, CR_STATE, and CR_DRAFT are
#                                empty, CR_REF is the repo and the branch,
#                                CR_TITLE counts the commits, DESC_PATH holds
#                                their messages, oldest first, IS_OWN_CR is 1,
#                                no thread is open, and REVIEW_STATUS_* and
#                                REVIEW_DECISIONS_PATH read the local record
#   BASE_BRANCH=<name>           HAS_CR=0 only: the open CR's branch this one is
#                                stacked on (lib/stack.sh), else the default
#                                branch; empty when HAS_CR=1, where the CR's own
#                                base SHA is the base
#   CR_IID=<number>              PR number / MR iid
#   CR_URL=<web url>
#   CR_TITLE=<title>
#   CR_AUTHOR=<username>         who wrote it — empty when the forge withheld it
#   CR_STATE=<open|merged|closed|…>  the forge's state, lowercased
#   CR_DRAFT=<true|false>
#   CR_HEAD_SHA=<sha>            the head under review, pinned at fetch time
#   CR_BASE_SHA=<sha>            the base the diff is taken against
#   CR_START_SHA=<sha>           GitLab's third position SHA; == base on GitHub
#   DIFF_RANGE=<base>...<head>   what to hand review-diff.sh
#   CHANGED_FILES=<n>            files in the range
#   DESC_PATH=<path>             the CR description, to read before the diff
#   DIFF_PATH=<path>             the unified diff of the range
#   FINDINGS_PATH=<path>         empty temp file for the skill's findings JSON
#   IS_OWN_CR=<0|1>              1 == the authenticated user wrote this CR
#   OPEN_THREADS=<n>             unresolved review threads a person started
#   OPEN_THREADS_MINE=<n>        how many of those the authenticated user started
#   OPEN_FEEDBACK_PATH=<path>    those threads as JSON: [{id, author, mine,
#                                file, line, body, replies}], body being the
#                                opening comment and replies the count after it
#
#   What the CR's Review status section says has been reviewed
#   (scripts/lib/review-status.sh). On the user's own CR a commit is reviewed
#   once any round covered it; on someone else's, once the user reviewed it:
#   REVIEW_STATUS_COMMITS=<n>    commits on the CR
#   REVIEW_STATUS_UNREVIEWED=<n> how many have had no such round
#   REVIEW_STATUS_OLDEST=<sha>   the oldest of those; empty when there are none
#   REVIEW_STATUS_LATEST=<sha>   the newest of those
#   REVIEW_STATUS_FROM=<sha>     the oldest one's parent: the base of a review
#                                that takes in every unreviewed commit
#   REVIEW_STATUS_DIFF_PATH=<path>  the diff from REVIEW_STATUS_FROM to the head
#
#   On any CR whose description has the section:
#   REVIEW_DECISIONS_PATH=<path> the decisions earlier reviews recorded there, as
#                                a JSON array of strings; [] without the section
#
# On a failure that leaves nothing to review it prints REVIEW_ERROR=<message>
# and exits non-zero, rather than emitting a half-populated block the skill
# would act on. An auth failure surfaces the same way (the fail-fast-on-auth
# rule) instead of degrading to a partial fetch.
#
# Usage:
#   review-cr.sh                      # the current branch's CR, or the branch itself where it has none
#   review-cr.sh 128                  # by number/iid, in the cwd repo
#   review-cr.sh <cr-url>             # by URL
#   review-cr.sh some-branch          # by source branch
#   review-cr.sh 128 --repo <path>    # against a checkout other than the cwd repo

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/review-status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-status.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stack.sh"

CTX_REPO=""
cr_ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --*) echo "review-cr.sh: unknown argument: $1" >&2; exit 64 ;;
    *)  [[ -n "$cr_ref" ]] && { echo "review-cr.sh: more than one CR reference: $cr_ref, $1" >&2; exit 64; }
        cr_ref="$1"; shift ;;
  esac
done

ctx_resolve_repo

die() { echo "REVIEW_ERROR=$*"; exit 65; }

origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
  *)            forge=none ;;
esac
# A CR URL names its own forge, which is the reliable signal when the argument
# points somewhere other than the checkout's origin.
case "$cr_ref" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
esac
[[ "$forge" == "none" ]] && die "origin is not a recognized forge, and no CR URL was given — nothing to review"

# --- A branch with no CR yet ---------------------------------------------------

# The branch's commits ahead of its base are the change, and their messages
# stand in for the description. The base is the default branch, or the branch of
# the open CR this one is stacked on, whose commits are that CR's to review. Its rounds are in the local record
# (scripts/lib/review-status.sh) until /anchor:prepare-review opens the CR.
resolve_branch() {
  local default count
  default=$(anchor_default_branch) || default=main
  [[ "$branch" != "$default" ]] || die "$branch is the default branch and has no CR — nothing to review"
  git fetch --quiet origin "$default" 2>/dev/null || true
  git rev-parse --verify --quiet "origin/$default^{commit}" >/dev/null 2>&1 \
    || die "origin/$default is not in this checkout — fetch it and re-run"
  base_branch=$(anchor_branch_base "$forge" "$branch" "$default" 2>&1) || die "$base_branch"
  if [[ "$base_branch" != "$default" ]]; then
    git fetch --quiet origin "$base_branch" 2>/dev/null || true
  fi
  cr_head=$(git rev-parse HEAD)
  cr_base=$(git merge-base "origin/$base_branch" HEAD)
  cr_start="$cr_base"
  count=$(git rev-list --count --no-merges "$cr_base..$cr_head")
  [[ "$count" -gt 0 ]] || die "$branch has no CR and no commits ahead of $base_branch — nothing to review"
  cr_title="$count commit$([[ "$count" -eq 1 ]] || echo s) ahead of $base_branch"
  cr_desc=$(git log --reverse --no-merges --format='## %s%n%n%b' "$cr_base..$cr_head")
  self=$(anchor_forge_self "$forge" 2>/dev/null) || self=""
  cr_author="$self"
  is_own=1
  local web
  web=$(anchor_repo_web_url)
  web="${web#https://}"
  host="${web%%/*}"
  project="${web#*/}"
  feedback_path=$(anchor_tmpfile "cr-review-feedback" json)
  echo '[]' > "$feedback_path"
  diff_range="${cr_base}...${cr_head}"
}

has_cr=1 branch="" base_branch=""
if [[ -z "$cr_ref" ]]; then
  branch=$(git symbolic-ref --quiet --short HEAD || true)
fi
if [[ -n "$branch" ]]; then
  case "$forge" in
    github) found=$(gh pr list --head "$branch" --state all --limit 1 --json number 2>&1) \
              || die "gh pr list failed: $(head -1 <<<"$found")" ;;
    gitlab) found=$(glab mr list --source-branch "$branch" --all --output json 2>&1) \
              || die "glab mr list failed: $(head -1 <<<"$found")" ;;
  esac
  found=$(jq length <<<"$found" 2>/dev/null) || die "could not read the CRs for $branch"
  [[ "$found" -gt 0 ]] || has_cr=0
fi

# --- Resolve the CR ----------------------------------------------------------

cr_iid=""; cr_url=""; cr_title=""; cr_author=""; cr_state=""; cr_draft=""
cr_head=""; cr_base=""; cr_start=""; cr_desc=""; self=""; project=""; host=""
is_own=0

resolve_cr() {

  case "$forge" in
    github)
      args=(--json 'number,url,title,author,isDraft,state,headRefOid,baseRefOid,body')
      [[ -n "$cr_ref" ]] && args=("$cr_ref" "${args[@]}")
      json=$(gh pr view "${args[@]}" 2>&1) || die "gh pr view failed: $(head -1 <<<"$json")"
      cr_iid=$(jq -r '.number // empty' <<<"$json")
      [[ -n "$cr_iid" ]] || die "no change request resolved from '${cr_ref:-the current branch}'"
      cr_url=$(jq -r '.url // empty' <<<"$json")
      cr_title=$(jq -r '.title // empty' <<<"$json")
      cr_author=$(jq -r '.author.login // empty' <<<"$json")
      cr_state=$(jq -r '.state // empty | ascii_downcase' <<<"$json")
      cr_draft=$(jq -r 'if .isDraft then "true" else "false" end' <<<"$json")
      cr_head=$(jq -r '.headRefOid // empty' <<<"$json")
      cr_base=$(jq -r '.baseRefOid // empty' <<<"$json")
      cr_start="$cr_base"
      cr_desc=$(jq -r '.body // ""' <<<"$json")
      ;;
    gitlab)
      args=(--output json)
      [[ -n "$cr_ref" ]] && args=("$cr_ref" "${args[@]}")
      json=$(glab mr view "${args[@]}" 2>&1) || die "glab mr view failed: $(head -1 <<<"$json")"
      cr_iid=$(jq -r '.iid // empty' <<<"$json" 2>/dev/null || true)
      [[ -n "$cr_iid" ]] || die "no change request resolved from '${cr_ref:-the current branch}'"
      cr_url=$(jq -r '.web_url // empty' <<<"$json")
      cr_title=$(jq -r '.title // empty' <<<"$json")
      cr_author=$(jq -r '.author.username // empty' <<<"$json")
      cr_state=$(jq -r '.state // empty | ascii_downcase' <<<"$json")
      cr_draft=$(jq -r 'if .draft then "true" else "false" end' <<<"$json")
      cr_desc=$(jq -r '.description // ""' <<<"$json")
      # diff_refs carries all three SHAs a line-anchored discussion's position
      # must pin to; `.sha` alone is the head and would leave the position
      # incomplete, which GitLab silently drops to an unanchored note.
      cr_head=$(jq -r '.diff_refs.head_sha // empty' <<<"$json")
      cr_base=$(jq -r '.diff_refs.base_sha // empty' <<<"$json")
      cr_start=$(jq -r '.diff_refs.start_sha // empty' <<<"$json")
      [[ -n "$cr_head" ]] || cr_head=$(jq -r '.sha // empty' <<<"$json")
      ;;
  esac
  self=$(anchor_forge_self "$forge" 2>/dev/null) || self=""

  [[ -n "$cr_head" ]] || die "the forge reported no head SHA for CR $cr_iid — nothing to anchor a review to"

  # Host and project come off the CR's own web URL rather than the cwd repo's
  # origin: an argument naming a CR in another project resolves through the CLI,
  # and the origin would then describe the wrong repo. GitLab nests projects to
  # any depth, so take everything between the host and the `/-/` separator.
  url_path="${cr_url#*://}"
  host="${url_path%%/*}"
  url_path="${url_path#*/}"
  case "$forge" in
    github) project="${url_path%%/pull/*}" ;;
    gitlab) project="${url_path%%/-/merge_requests/*}" ;;
  esac

  [[ -n "$self" && "$self" == "$cr_author" ]] && is_own=1

  # --- Open feedback -------------------------------------------------------------

  # Threads already open on the CR come before any new pass: on the author's own
  # CR they are what /anchor:resolve-feedback works, and on someone else's they
  # are the questions the next head is supposed to answer.
  feedback_path=$(anchor_tmpfile "cr-review-feedback" json)
  case "$forge" in
    github)
      owner="${project%%/*}"; repo_name="${project#*/}"
      # GraphQL variables, not shell ones: the single quotes are deliberate.
      # shellcheck disable=SC2016
      threads=$(gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
        repository(owner:$owner,name:$repo){pullRequest(number:$pr){
          reviewThreads(first:100){nodes{id isResolved path line
            comments(first:50){nodes{author{login} body}}}}}}}' \
        -f owner="$owner" -f repo="$repo_name" -F pr="$cr_iid" 2>&1) \
        || die "could not read the CR's review threads: $(head -1 <<<"$threads")"
      jq --arg self "$self" '[.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved | not)
        | (.comments.nodes[0]) as $first
        | {id, author:($first.author.login // ""), mine:(($first.author.login // "") == $self),
           file:.path, line, body:($first.body // ""), replies:((.comments.nodes | length) - 1)}]' \
        <<<"$threads" > "$feedback_path"
      ;;
    gitlab)
      gl_args=(api)
      [[ "$host" == "gitlab.com" ]] || gl_args+=(--hostname "$host")
      threads=$(glab "${gl_args[@]}" "projects/$(jq -rn --arg p "$project" '$p | @uri')/merge_requests/${cr_iid}/discussions?per_page=100" 2>&1) \
        || die "could not read the MR's discussions: $(head -1 <<<"$threads")"
      jq --arg self "$self" '[.[] | select(.notes[0].system == false)
        | select([.notes[] | .resolvable and (.resolved | not)] | any)
        | (.notes[0]) as $first
        | {id, author:($first.author.username // ""), mine:(($first.author.username // "") == $self),
           file:($first.position.new_path // null), line:($first.position.new_line // null),
           body:($first.body // ""), replies:((.notes | length) - 1)}]' \
        <<<"$threads" > "$feedback_path"
      ;;
  esac

  # --- Fetch the head into the local checkout ----------------------------------

  # Both forges publish every CR head under a read-only ref namespace, so this
  # reaches a fork-sourced CR without adding a remote and without touching the
  # working tree or the current branch.
  case "$forge" in
    github) cr_ref_spec="refs/pull/${cr_iid}/head" ;;
    gitlab) cr_ref_spec="refs/merge-requests/${cr_iid}/head" ;;
  esac
  git fetch --quiet origin "+${cr_ref_spec}:refs/anchor-review/${cr_iid}" 2>/dev/null \
    || die "could not fetch ${cr_ref_spec} from origin — the CR head is not reachable from this checkout"

  git rev-parse --verify --quiet "$cr_head^{commit}" >/dev/null 2>&1 \
    || die "fetched ${cr_ref_spec} but head ${cr_head} is missing — the CR moved between the metadata read and the fetch; re-run"

  # The base is on the target branch, which a shallow or stale checkout may not
  # have. Fetching it by SHA needs uploadpack.allowReachableSHA1InWant, so fetch
  # every ref and let the three-dot range find the merge base — but only once the
  # base has turned out to be missing, since an up-to-date checkout is the common
  # case and that fetch walks the whole remote.
  anchor_fetch_commit "$cr_base" \
    || die "the CR's base commit ${cr_base} is not in this checkout — fetch the target branch and re-run"

  diff_range="${cr_base}...${cr_head}"
}

if [[ "$has_cr" -eq 1 ]]; then
  resolve_cr
else
  resolve_branch
fi

# --- Artifacts ---------------------------------------------------------------

desc_path=$(anchor_tmpfile "cr-review-desc")
diff_path=$(anchor_tmpfile "cr-review-diff" diff)
findings_path=$(anchor_tmpfile "cr-review-findings" json)

printf '%s\n' "$cr_desc" > "$desc_path"
git diff "$diff_range" > "$diff_path"
# Counted off the diff just written rather than by re-walking the range: one
# header per changed file, and a `+diff --git` inside a hunk can't match.
changed_files=$(grep -c '^diff --git ' "$diff_path" || true)

# Seeded rather than left empty so the skill writes findings into a file whose
# shape review-post.sh already accepts, and a review that finds nothing is a
# valid document rather than an unparseable one.
jq -n --arg url "$cr_url" --arg head "$cr_head" \
  '{cr: {url: $url, headSha: $head}, summary: "", comments: []}' > "$findings_path"

echo "RESOLVED_VIA=$RESOLVED_VIA"
echo "FORGE=$forge"
echo "HOST=$host"
echo "PROJECT=$project"
echo "HAS_CR=$has_cr"
echo "BASE_BRANCH=$base_branch"
echo "CR_IID=$cr_iid"
# How a reader names the CR: the repo, then the number with the forge's own
# marker, so a round title can't read the number as a count.
if [[ "$has_cr" -eq 0 ]]; then repo_name=${origin_url%.git}; echo "CR_REF=${repo_name##*[/:]} $branch"
else echo "CR_REF=$(anchor_cr_reference "$cr_url" "$cr_iid" ' ')"; fi
echo "CR_URL=$cr_url"
echo "CR_TITLE=$cr_title"
echo "CR_AUTHOR=$cr_author"
echo "CR_STATE=$cr_state"
echo "CR_DRAFT=$cr_draft"
echo "CR_HEAD_SHA=$cr_head"
echo "CR_BASE_SHA=$cr_base"
echo "CR_START_SHA=$cr_start"
echo "DIFF_RANGE=$diff_range"
echo "CHANGED_FILES=$changed_files"
echo "DESC_PATH=$desc_path"
echo "DIFF_PATH=$diff_path"
echo "FINDINGS_PATH=$findings_path"
echo "IS_OWN_CR=$is_own"
echo "OPEN_THREADS=$(jq length "$feedback_path")"
echo "OPEN_THREADS_MINE=$(jq '[.[] | select(.mine)] | length' "$feedback_path")"
echo "OPEN_FEEDBACK_PATH=$feedback_path"

if [[ "$has_cr" -eq 1 ]]; then
  recorded=$(review_status_data "$desc_path") \
    || die "the CR's Review status section holds data that isn't JSON; fix or delete its opening comment"
else
  recorded=$(review_status_local_data) \
    || die "the local review record at $(review_status_local_path) isn't JSON; fix or delete it"
  recorded=$(review_status_pick "$recorded" "$cr_base" "$cr_head")
fi
decisions_path=$(anchor_tmpfile "cr-review-decisions" json)
review_status_notes "$recorded" > "$decisions_path"
echo "REVIEW_DECISIONS_PATH=$decisions_path"

rows=$(review_status_rows "$recorded" "$cr_base" "$cr_head")
unreviewed=$(jq -c --arg me "$self" --argjson own "$is_own" \
  '[.[] | select(if $own == 1 then .rounds == 0 else (.by | index([$me])) == null end) | .sha]' <<<"$rows")
oldest=$(jq -r '.[0] // empty' <<<"$unreviewed")
from="" status_diff=""
if [[ -n "$oldest" ]]; then
  from=$(git rev-parse "$oldest^")
  status_diff=$(anchor_tmpfile "cr-review-unreviewed" diff)
  git diff "$from" "$cr_head" > "$status_diff"
fi
echo "REVIEW_STATUS_COMMITS=$(jq length <<<"$rows")"
echo "REVIEW_STATUS_UNREVIEWED=$(jq length <<<"$unreviewed")"
echo "REVIEW_STATUS_OLDEST=$oldest"
echo "REVIEW_STATUS_LATEST=$(jq -r '.[-1] // empty' <<<"$unreviewed")"
echo "REVIEW_STATUS_FROM=$from"
echo "REVIEW_STATUS_DIFF_PATH=$status_diff"
