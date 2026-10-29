#!/usr/bin/env bash
# Record a review round in a CR's Review status section: every commit in the
# reviewed range gets another round, by the signed-in user, with the round's
# result as its latest. The section is the CR's memory of what has been reviewed, read
# back by /anchor:review to suggest the commits nobody has reviewed yet and by
# /anchor:merge to warn before landing any of them. The section's shape and how
# a commit is keyed are in scripts/lib/review-status.sh.
#
# Why a script (not skill prose): which commits a range holds, matching them to
# what was recorded across a rebase, and rewriting one section of a description
# without touching the rest are deterministic. Whether a review happened, and
# what it found, is the skill's to say.
#
# The author's own CR gets the section whether or not it has one yet. Someone
# else's is written to only where the section is already there, since its author
# opted in by keeping one, and only once the CR is out of draft, since a draft
# is the author saying it isn't ready for review. The description is read fresh
# just before it is written, so an edit made since the review began survives.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>
#   STATUS_RECORDED=<n>        commits given another round; 0 when skipped
#   STATUS_SKIPPED=<reason>    nothing was written, on someone else's CR:
#                              no-section (its description has none) or draft
#   STATUS_UNREVIEWED=<n>      commits on the CR still at no rounds
#   STATUS_SECTION_PATH=<path> the section as written, to show the user
#
# On a failure it prints STATUS_ERROR=<message> on stderr and exits non-zero; an
# authentication failure is marked STATUS_AUTH=1 so the caller asks for fresh
# credentials instead of retrying.
#
# `carry` puts a section back into a description drafted without it: the
# drafting reviews the description with the section taken out
# (scripts/prepare-review.sh, CR_REVIEW_STATUS_PATH), and the write puts it back.
# It prints STATUS_CARRIED=<0|1>.
#
# Usage:
#   review-status.sh record --cr <n> --base <sha> --head <sha> --result <approved|changes-requested> [--repo <path>]
#   review-status.sh carry  --section <file> --into <draft>

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/review-status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-status.sh"

usage() {
  echo "usage: review-status.sh record --cr <n> --base <sha> --head <sha> --result <approved|changes-requested> [--repo <path>]" >&2
  echo "       review-status.sh carry --section <file> --into <draft>" >&2
  exit 64
}

die() {
  echo "STATUS_ERROR=$1: $2" >&2
  if grep -qiE '401|403|unauthori[sz]ed|forbidden|authentication|not logged in|gh auth login|glab auth login' <<<"$2"; then
    echo "STATUS_AUTH=1" >&2
  fi
  exit 70
}

if [[ "${1:-}" == carry ]]; then
  shift
  section="" into=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --section) section="${2:?--section needs a file}"; shift 2 ;;
      --into)    into="${2:?--into needs a file}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -f "$section" && -f "$into" ]] || usage
  if [[ ! -s "$section" ]]; then
    echo "STATUS_CARRIED=0"
    exit 0
  fi
  carried=$(anchor_tmpfile cr-review-status-carried md)
  review_status_splice "$into" "$section" > "$carried"
  mv "$carried" "$into"
  echo "STATUS_CARRIED=1"
  exit 0
fi
[[ "${1:-}" == record ]] || usage
shift

CTX_REPO="" cr="" base="" head="" result=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cr)     cr="${2:?--cr needs a number}"; shift 2 ;;
    --base)   base="${2:?--base needs a sha}"; shift 2 ;;
    --head)   head="${2:?--head needs a sha}"; shift 2 ;;
    --result) result="${2:?--result needs a verdict}"; shift 2 ;;
    --repo)   CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$cr" && -n "$base" && -n "$head" ]] || usage
case "$result" in
  approved|changes-requested) ;;
  *) echo "review-status.sh: --result must be approved or changes-requested, got: $result" >&2; exit 64 ;;
esac

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

for sha in "$base" "$head"; do
  git rev-parse --verify --quiet "$sha^{commit}" >/dev/null \
    || { echo "STATUS_ERROR=$sha is not a commit in this checkout" >&2; exit 65; }
done
git merge-base --is-ancestor "$base" "$head" \
  || { echo "STATUS_ERROR=--base $base is not an ancestor of --head $head" >&2; exit 65; }

desc=$(anchor_tmpfile cr-review-status md)
forge=$(anchor_forge_of_origin)
case "$forge" in
  github)
    view=$(gh pr view "$cr" --json author,body,baseRefOid,headRefOid,isDraft 2>&1) || die "could not read the CR" "$view"
    draft=$(jq -r '.isDraft // false' <<<"$view")
    author=$(jq -r '.author.login // empty' <<<"$view")
    cr_base=$(jq -r '.baseRefOid' <<<"$view")
    cr_head=$(jq -r '.headRefOid' <<<"$view")
    jq -r '.body // ""' <<<"$view" > "$desc"
    self=$(gh api user 2>&1) || die "could not read the signed-in user" "$self"
    self=$(jq -r '.login // empty' <<<"$self")
    ;;
  gitlab)
    view=$(glab mr view "$cr" --output json 2>&1) || die "could not read the CR" "$view"
    author=$(jq -r '.author.username // empty' <<<"$view")
    cr_base=$(jq -r '.diff_refs.base_sha' <<<"$view")
    cr_head=$(jq -r '.sha' <<<"$view")
    draft=$(jq -r '.draft // .work_in_progress // false' <<<"$view")
    jq -r '.description // ""' <<<"$view" > "$desc"
    self=$(glab api user 2>&1) || die "could not read the signed-in user" "$self"
    self=$(jq -r '.username // empty' <<<"$self")
    ;;
  *) echo "STATUS_ERROR=origin is neither GitHub nor GitLab" >&2; exit 69 ;;
esac

if [[ -z "$self" || "$self" != "$author" ]]; then
  skipped=""
  if ! grep -q "<!-- $REVIEW_STATUS_MARK " "$desc"; then
    skipped=no-section
  elif [[ "$draft" == true ]]; then
    skipped=draft
  fi
  if [[ -n "$skipped" ]]; then
    echo "STATUS_RECORDED=0"
    echo "STATUS_SKIPPED=$skipped"
    exit 0
  fi
fi

# The CR's base is on the target branch, which a stale checkout may not have.
if ! git rev-parse --verify --quiet "$cr_base^{commit}" >/dev/null; then
  git fetch --quiet origin 2>/dev/null || true
  git rev-parse --verify --quiet "$cr_base^{commit}" >/dev/null \
    || { echo "STATUS_ERROR=the CR's base commit $cr_base is not in this checkout; fetch the target branch and re-run" >&2; exit 65; }
fi

# The table runs to the CR's head when it is past the reviewed one. Just after a
# push the forge can still report the head before it, so the reviewed head is
# the floor.
tip=$head
if git rev-parse --verify --quiet "$cr_head^{commit}" >/dev/null && git merge-base --is-ancestor "$head" "$cr_head"; then
  tip=$cr_head
fi

recorded=$(review_status_data "$desc") \
  || { echo "STATUS_ERROR=the CR's Review status section holds data that isn't JSON; fix or delete its opening comment" >&2; exit 65; }
data=$(review_status_add "$recorded" "$base" "$head" "$result" "$self")
rows=$(review_status_rows "$data" "$cr_base" "$tip")
section=$(anchor_tmpfile cr-review-status-section md)
review_status_section "$data" "$rows" > "$section"
updated=$(anchor_tmpfile cr-review-status-desc md)
review_status_splice "$desc" "$section" > "$updated"

case "$forge" in
  github) out=$(gh pr edit "$cr" --body-file "$updated" 2>&1) || die "could not write the CR description" "$out" ;;
  gitlab) out=$(glab api -X PUT "projects/:fullpath/merge_requests/$cr" -F "description=@$updated" 2>&1) \
            || die "could not write the CR description" "$out" ;;
esac

echo "STATUS_RECORDED=$(git rev-list --count --no-merges "$base..$head")"
echo "STATUS_UNREVIEWED=$(jq '[.[] | select(.rounds == 0)] | length' <<<"$rows")"
echo "STATUS_SECTION_PATH=$section"
