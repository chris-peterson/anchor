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
#   RESOLVED_VIA=<worktree|repo|cwd>  which checkout the run operated in
#   FORGE=<github|gitlab>        picks the CLI for the rest of the flow
#   HOST=<host>                  e.g. gitlab.example.com (glab --hostname)
#   PROJECT=<owner/name>         full project path after the host, any depth
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
#
# On a failure that leaves nothing to review it prints REVIEW_ERROR=<message>
# and exits non-zero, rather than emitting a half-populated block the skill
# would act on. An auth failure surfaces the same way (the fail-fast-on-auth
# rule) instead of degrading to a partial fetch.
#
# Usage:
#   review-cr.sh                      # the open CR for the current branch
#   review-cr.sh 128                  # by number/iid, in the cwd repo
#   review-cr.sh <cr-url>             # by URL
#   review-cr.sh some-branch          # by source branch
#   review-cr.sh 128 --repo <path>    # against a checkout other than the cwd repo

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

CTX_REPO=""
CTX_WORKTREE=""
cr_ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
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

# --- Resolve the CR ----------------------------------------------------------

cr_iid=""; cr_url=""; cr_title=""; cr_author=""; cr_state=""; cr_draft=""
cr_head=""; cr_base=""; cr_start=""; cr_desc=""; self=""; project=""

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
    self=$(gh api user --jq .login 2>/dev/null || true)
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
    self=$(glab api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)
    ;;
esac

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

is_own=0
[[ -n "$self" && "$self" == "$cr_author" ]] && is_own=1

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
if ! git rev-parse --verify --quiet "$cr_base^{commit}" >/dev/null 2>&1; then
  git fetch --quiet origin 2>/dev/null || true
  git rev-parse --verify --quiet "$cr_base^{commit}" >/dev/null 2>&1 \
    || die "the CR's base commit ${cr_base} is not in this checkout — fetch the target branch and re-run"
fi

diff_range="${cr_base}...${cr_head}"

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
echo "CR_IID=$cr_iid"
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
