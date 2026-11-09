#!/usr/bin/env bash
# Record a review round in a CR's Review status section: every commit in the
# reviewed range gets another round, by the signed-in user, with the round's
# result and kind as its latest. The section is the CR's memory of what has been reviewed, read
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
# Before the write, the CR is saved through scripts/forge-backup.sh (FORGE-13).
# The section is written without an approval of its text (CONFIRM-17), so the
# check is against the CR this script read: a backup of any other CR stops the
# write.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>
#   CR_BACKUP_PATH=<path>      the CR as it was before the write, saved as JSON
#                              under <git-common-dir>/anchor/backups/; only
#                              on a run that writes the CR (not --local, not
#                              STATUS_SKIPPED)
#   STATUS_RECORDED=<n>        commits given another round; 0 when skipped
#   STATUS_SKIPPED=<reason>    nothing was written, on someone else's CR:
#                              no-section (its description has none) or draft
#   STATUS_UNREVIEWED=<n>      commits on the CR still at no rounds
#   STATUS_ROWS_PATH=<path>    the CR's commits as recorded, oldest first, as
#                              [{sha, key, rounds, by, result, kind, notes}], to show
#                              the user
#
# On a failure it prints STATUS_ERROR=<message> on stderr and exits non-zero; an
# authentication failure is marked STATUS_AUTH=1 so the caller asks for fresh
# credentials instead of retrying.
#
# --kind is `agent-assisted` (the default) when quality agents examined the
# range, `read-through` when only the reviewer read it.
#
# --note records a decision the review made (one per flag), on the newest commit
# the round reviewed; the wording is the caller's.
#
# --local records a branch that has no CR yet: the round goes to the local
# record in the repo's git directory (scripts/lib/review-status.sh) rather than
# to a description, and the rows run from where the branch leaves the default
# branch. /anchor:prepare-review carries those rounds into the CR it opens.
#
# Usage:
#   review-status.sh record (--cr <n> | --local) --base <sha> --head <sha> --result <approved|changes-requested> [--kind <agent-assisted|read-through>] [--note <text>]... [--repo <path>]

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/review-status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-status.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

usage() {
  echo "usage: review-status.sh record (--cr <n> | --local) --base <sha> --head <sha> --result <approved|changes-requested> [--kind <agent-assisted|read-through>] [--note <text>]... [--repo <path>]" >&2
  exit 64
}

die() {
  echo "STATUS_ERROR=$1: $2" >&2
  if grep -qiE '401|403|unauthori[sz]ed|forbidden|authentication|not logged in|gh auth login|glab auth login' <<<"$2"; then
    echo "STATUS_AUTH=1" >&2
  fi
  exit 70
}

[[ "${1:-}" == record ]] || usage
shift

CTX_REPO="" cr="" base="" head="" result="" kind=agent-assisted local=0
notes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --note)   notes+=("${2:?--note needs text}"); shift 2 ;;
    --cr)     cr="${2:?--cr needs a number}"; shift 2 ;;
    --local)  local=1; shift ;;
    --base)   base="${2:?--base needs a sha}"; shift 2 ;;
    --head)   head="${2:?--head needs a sha}"; shift 2 ;;
    --result) result="${2:?--result needs a verdict}"; shift 2 ;;
    --kind)   kind="${2:?--kind needs agent-assisted or read-through}"; shift 2 ;;
    --repo)   CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$base" && -n "$head" ]] || usage
[[ -n "$cr" && "$local" -eq 0 || -z "$cr" && "$local" -eq 1 ]] || usage
case "$result" in
  approved|changes-requested) ;;
  *) echo "review-status.sh: --result must be approved or changes-requested, got: $result" >&2; exit 64 ;;
esac
case "$kind" in
  agent-assisted|read-through) ;;
  *) echo "review-status.sh: --kind must be agent-assisted or read-through, got: $kind" >&2; exit 64 ;;
esac

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

for sha in "$base" "$head"; do
  git rev-parse --verify --quiet "$sha^{commit}" >/dev/null \
    || { echo "STATUS_ERROR=$sha is not a commit in this checkout" >&2; exit 65; }
done
git merge-base --is-ancestor "$base" "$head" \
  || { echo "STATUS_ERROR=--base $base is not an ancestor of --head $head" >&2; exit 65; }

forge=$(anchor_forge_of_origin)
[[ "$forge" != none ]] || { echo "STATUS_ERROR=origin is neither GitHub nor GitLab" >&2; exit 69; }
self=$(anchor_forge_self "$forge") || die "could not read the signed-in user" "$self"

if [[ "$local" -eq 1 ]]; then
  default=$(anchor_default_branch) || default=main
  git rev-parse --verify --quiet "origin/$default^{commit}" >/dev/null \
    || { echo "STATUS_ERROR=origin/$default is not in this checkout; fetch it and re-run" >&2; exit 65; }
  recorded=$(review_status_local_data) \
    || { echo "STATUS_ERROR=the local review record at $(review_status_local_path) isn't JSON; fix or delete it" >&2; exit 65; }
  data=$(review_status_add "$recorded" "$base" "$head" "$result" "$kind" "$self" "${notes[@]+"${notes[@]}"}")
  review_status_local_write "$data"
  tip=$head
  git merge-base --is-ancestor "$head" HEAD && tip=HEAD
  rows=$(anchor_tmpfile cr-review-status-rows json)
  review_status_rows "$data" "$(git merge-base "origin/$default" "$tip")" "$tip" > "$rows"
  echo "STATUS_RECORDED=$(git rev-list --count --no-merges "$base..$head")"
  echo "STATUS_UNREVIEWED=$(jq '[.[] | select(.rounds == 0)] | length' "$rows")"
  echo "STATUS_ROWS_PATH=$rows"
  exit 0
fi

desc=$(anchor_tmpfile cr-review-status md)
case "$forge" in
  github)
    view=$(gh pr view "$cr" --json author,body,baseRefOid,headRefOid,isDraft,url 2>&1) || die "could not read the CR" "$view"
    cr_url=$(jq -r '.url // empty' <<<"$view")
    draft=$(jq -r '.isDraft // false' <<<"$view")
    author=$(jq -r '.author.login // empty' <<<"$view")
    cr_base=$(jq -r '.baseRefOid' <<<"$view")
    cr_head=$(jq -r '.headRefOid' <<<"$view")
    jq -r '.body // ""' <<<"$view" > "$desc"
    ;;
  gitlab)
    view=$(glab mr view "$cr" --output json 2>&1) || die "could not read the CR" "$view"
    author=$(jq -r '.author.username // empty' <<<"$view")
    cr_url=$(jq -r '.web_url // empty' <<<"$view")
    cr_base=$(jq -r '.diff_refs.base_sha' <<<"$view")
    cr_head=$(jq -r '.sha' <<<"$view")
    draft=$(jq -r '.draft // .work_in_progress // false' <<<"$view")
    jq -r '.description // ""' <<<"$view" > "$desc"
    ;;
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
anchor_fetch_commit "$cr_base" \
  || { echo "STATUS_ERROR=the CR's base commit $cr_base is not in this checkout; fetch the target branch and re-run" >&2; exit 65; }

# The table runs to the CR's head when it is past the reviewed one. Just after a
# push the forge can still report the head before it, so the reviewed head is
# the floor.
tip=$head
if git rev-parse --verify --quiet "$cr_head^{commit}" >/dev/null && git merge-base --is-ancestor "$head" "$cr_head"; then
  tip=$cr_head
fi

recorded=$(review_status_data "$desc") \
  || { echo "STATUS_ERROR=the CR's Review status section holds data that isn't JSON; fix or delete its opening comment" >&2; exit 65; }
data=$(review_status_add "$recorded" "$base" "$head" "$result" "$kind" "$self" "${notes[@]+"${notes[@]}"}")
rows=$(anchor_tmpfile cr-review-status-rows json)
review_status_rows "$data" "$cr_base" "$tip" > "$rows"
section=$(anchor_tmpfile cr-review-status-section md)
review_status_section "$data" > "$section"
updated=$(anchor_tmpfile cr-review-status-desc md)
review_status_splice "$desc" "$section" > "$updated"

backup=$(anchor_backup_cr "$cr" "$cr_url") || die "could not back up the CR before writing it" "$backup"
echo "CR_BACKUP_PATH=$backup"
out=$(anchor_cr_write_description "$forge" "$cr" "$updated") || die "could not write the CR description" "$out"

echo "STATUS_RECORDED=$(git rev-list --count --no-merges "$base..$head")"
echo "STATUS_UNREVIEWED=$(jq '[.[] | select(.rounds == 0)] | length' "$rows")"
echo "STATUS_ROWS_PATH=$rows"
