#!/usr/bin/env bash
# Save an issue, a change request, or a milestone as the forge holds it, before
# a skill overwrites any of it (FORGE-13).
#
# Why a script (not skill prose): the read is deterministic and differs per
# forge and per kind, and a skill improvising it each time is a skill that
# sometimes skips it. The skill runs this, checks BACKUP_URL is the item it
# presented for approval, then writes.
#
# The whole object is saved, not one field, because a single edit can change
# the title, body, labels, milestone, and state together.
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>
#   BACKUP_PATH=<path>     the saved JSON, under <git-common-dir>/anchor/backups/
#   BACKUP_URL=<web url>   the item as the forge names it
#   BACKUP_TITLE=<title>
#
# On a read that fails (no such item, an auth error) it prints
# BACKUP_ERROR=<message> and exits 1: the write it guards should not go ahead.
#
# Exit codes: 0 saved · 1 the read or the save failed · 64 usage error
#
# Usage:
#   forge-backup.sh --kind <issue|cr|milestone> --id <n> [--repo <path>]
#                   [--project <owner/name|group/project>] [--hostname <host>]
#
# --project names a project other than origin's; the forge is still origin's.
# A GitHub milestone and every GitLab kind are read by number through the API,
# a GitLab milestone by its id (not its iid).

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

CTX_REPO=""
kind=""
id=""
project=""
hostname=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)     kind="${2:?--kind needs a value}"; shift 2 ;;
    --id)       id="${2:?--id needs a value}"; shift 2 ;;
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --project)  project="${2:?--project needs a path}"; shift 2 ;;
    --hostname) hostname="${2:?--hostname needs a host}"; shift 2 ;;
    *) echo "forge-backup.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
case "$kind" in
  issue|cr|milestone) ;;
  *) echo "forge-backup.sh: --kind must be issue, cr, or milestone" >&2; exit 64 ;;
esac
[[ -n "$id" ]] || { echo "forge-backup.sh: --id is required" >&2; exit 64; }

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

forge=$(anchor_forge_of_origin)
host_args=()
[[ -z "$hostname" ]] || host_args=(--hostname "$hostname")

case "$forge" in
  github)
    repo_args=()
    gh_repo='{owner}/{repo}'
    [[ -z "$project" ]] || { repo_args=(-R "$project"); gh_repo=$project; }
    case "$kind" in
      issue) read_cmd=(gh issue view "$id" ${repo_args[@]+"${repo_args[@]}"} --json "number,title,body,labels,milestone,state,url") ;;
      cr)    read_cmd=(gh pr view "$id" ${repo_args[@]+"${repo_args[@]}"} --json "number,title,body,labels,milestone,state,url,headRefName") ;;
      milestone) read_cmd=(gh api ${host_args[@]+"${host_args[@]}"} "repos/$gh_repo/milestones/$id") ;;
    esac ;;
  gitlab)
    enc=":fullpath"
    [[ -z "$project" ]] || enc=$(printf '%s' "$project" | jq -sRr @uri)
    case "$kind" in
      issue)     read_cmd=(glab api ${host_args[@]+"${host_args[@]}"} "projects/$enc/issues/$id") ;;
      cr)        read_cmd=(glab api ${host_args[@]+"${host_args[@]}"} "projects/$enc/merge_requests/$id") ;;
      milestone) read_cmd=(glab api ${host_args[@]+"${host_args[@]}"} "projects/$enc/milestones/$id") ;;
    esac ;;
  *) echo "BACKUP_ERROR=origin is neither GitHub nor GitLab"; exit 1 ;;
esac

if ! json=$("${read_cmd[@]}" 2>&1); then
  echo "BACKUP_ERROR=could not read $kind $id: $json"
  exit 1
fi

name="$kind-$id"
[[ -z "$project" ]] || name="${project//[^[:alnum:]]/-}-$name"
if ! path=$(anchor_backup_path "$name" json); then
  echo "BACKUP_ERROR=not in a git repository, so there is nowhere to keep the backup"
  exit 1
fi
printf '%s\n' "$json" > "$path"

echo "BACKUP_PATH=$path"
echo "BACKUP_URL=$(jq -r '.url // .html_url // .web_url // empty' <<<"$json")"
echo "BACKUP_TITLE=$(jq -r '.title // empty' <<<"$json")"
