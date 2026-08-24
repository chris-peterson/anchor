#!/usr/bin/env bash
# Resolve a *named* target repo to its forge facts, so anchor's forge skills can
# operate on a repo by name instead of inferring it from the cwd's origin remote
# (which is only right when the cwd repo IS the target). Given `file an issue
# against <name>` / `open the MR in <name>`, the skill passes <name> here rather
# than guessing.
#
# The lookup runs against the forge CLIs anchor already requires. A repo's name
# and location are facts about the machine and the forge, so resolution asks the
# forge directly rather than routing through a second plugin's store.
#
# Three input shapes, cheapest first:
#
#   1. A remote URL (`https://host/group/repo`, `git@host:group/repo.git`) or a
#      host-qualified path (`host/group/repo`) carries its own host and project
#      — parsed, with no forge call at all.
#   2. A slug (`owner/repo`, `group/subgroup/repo`) is probed directly on each
#      authenticated host: `gh api repos/<slug>` · `glab api projects/<encoded>`.
#   3. A bare name is matched against the repos you can reach — `gh api
#      /user/repos` (owner, collaborator, and org-member affiliations) and `glab
#      api projects?membership=true`. GitLab's endpoint matches by *substring*,
#      so both lists are filtered to an exact, case-insensitive basename.
#
# Hosts come from `gh auth status` and `glab auth status --all`, which print a
# host at column zero followed by a `Logged in to` line once it is authenticated.
# A host that is configured but not authenticated is skipped; when that leaves
# nothing to query, the note says so rather than reporting a match that failed.
#
# Usage:
#   resolve-target.sh <repo-name>
#
# Output (KEY=value on stdout):
#   TARGET_VIA=<resolved|ambiguous|cwd>
#     resolved   — exactly one repo; the fields below are populated
#     ambiguous  — >1 match; TARGET_CANDIDATES holds them for the skill to prompt
#     cwd        — no match; caller falls back to cwd/origin
#   TARGET_NOTE=<text>          why it fell back (present on the cwd path)
#   TARGET_CANDIDATES=<json>    [{key,url,local}] to disambiguate (ambiguous only)
#   TARGET_URL=<url>            canonical https remote           (resolved only)
#   TARGET_FORGE=<github|gitlab|other>   picks the CLI            (resolved only)
#   TARGET_HOST=<host>          e.g. gitlab.example.com (glab --hostname) (resolved)
#   TARGET_PROJECT=<path>       full project path after the host, any depth
#                               (gh -R owner/repo · glab :fullpath / -R)  (resolved)
#   TARGET_LOCAL=<path>         the working directory's repo when its origin is
#                               the repo that resolved, else empty. Empty means
#                               no known checkout: operations that read repo
#                               files or need a work tree must be degraded or
#                               handed an explicit --repo    (resolved only)

set -euo pipefail

name="${1:?usage: resolve-target.sh <repo-name>}"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# `git@host:group/repo.git` / `https://host/group/repo` / `host/group/repo`
# -> `host/group/repo`. Returns 1 for anything that isn't host-qualified.
normalize_remote() {
  local u="$1"
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    *://*)  u="${u#*://}"; u="${u#*@}" ;;
    *@*:*)  u="${u#*@}"; u="${u/:/\/}" ;;
    */*)    [[ "${u%%/*}" == *.* ]] || return 1 ;;
    *)      return 1 ;;
  esac
  [[ "$u" == */* ]] || return 1
  printf '%s' "$u"
}

# Both CLIs print a bare host at column zero, then indent its details; the host
# is authenticated when a `Logged in to` line arrives before the next host.
authed_hosts() {
  local out line host=""
  out=$("$@" 2>&1) || true
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
      host="${BASH_REMATCH[1]}"
    elif [[ -n "$host" && "$line" == *"Logged in to"* ]]; then
      printf '%s\n' "$host"; host=""
    fi
  done <<<"$out"
}

gh_hosts=""
glab_hosts=""
hosts_loaded=""
load_hosts() {
  [[ -n "$hosts_loaded" ]] && return 0
  hosts_loaded=1
  if command -v gh >/dev/null 2>&1; then
    gh_hosts=$(authed_hosts gh auth status || true)
  fi
  if command -v glab >/dev/null 2>&1; then
    glab_hosts=$(authed_hosts glab auth status --all || true)
  fi
}

host_in() { printf '%s\n' "$2" | grep -qxF "$1"; }

# The host name settles the forge for every hosted instance that keeps the
# vendor in its domain, which costs nothing; only a host that hides it (a GitHub
# Enterprise at `git.corp.example`) is worth an auth round-trip to classify.
forge_for_host() {
  case "$1" in
    *github*) echo github; return ;;
    *gitlab*) echo gitlab; return ;;
  esac
  load_hosts
  if host_in "$1" "$gh_hosts"; then echo github; return; fi
  if host_in "$1" "$glab_hosts"; then echo gitlab; return; fi
  echo other
}

# TARGET_LOCAL: the working directory's repo, but only when its origin is the
# repo that resolved. Any other checkout on the machine is unknown to us.
local_checkout() {
  local top origin norm
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  origin=$(git -C "$top" remote get-url origin 2>/dev/null) || return 0
  norm=$(normalize_remote "$origin") || return 0
  [[ "$(lower "$norm")" == "$(lower "$1")" ]] && printf '%s' "$top"
  return 0
}

emit_resolved() {  # <host> <project> <url>
  echo "TARGET_VIA=resolved"
  echo "TARGET_URL=$3"
  echo "TARGET_FORGE=$(forge_for_host "$1")"
  echo "TARGET_HOST=$1"
  echo "TARGET_PROJECT=$2"
  echo "TARGET_LOCAL=$(local_checkout "$1/$2")"
}

fall_back_to_cwd() {
  echo "TARGET_VIA=cwd"
  echo "TARGET_NOTE=$1"
}

# --- 1. a remote URL or host-qualified path answers itself --------------------
if key=$(normalize_remote "$name"); then
  emit_resolved "${key%%/*}" "${key#*/}" "https://$key"
  exit 0
fi

load_hosts
if [[ -z "$gh_hosts" && -z "$glab_hosts" ]]; then
  fall_back_to_cwd "no authenticated forge to query for '$name'; resolving from cwd"
  exit 0
fi

candidates='[]'
add_candidate() {  # <host> <project> <url>
  candidates=$(jq -c --arg k "$1/$2" --arg u "$3" --arg l "$(local_checkout "$1/$2")" \
    '. + [{key:$k, url:$u, local:$l}]' <<<"$candidates")
}

urlenc_path() { printf '%s' "$1" | sed 's|/|%2F|g'; }

if [[ "$name" == */* ]]; then
  # --- 2. a slug names its project exactly; probe it on each host -------------
  for host in $gh_hosts; do
    repo=$(gh api --hostname "$host" "repos/$name" 2>/dev/null) || continue
    add_candidate "$host" \
      "$(jq -r '.full_name' <<<"$repo")" "$(jq -r '.html_url' <<<"$repo")"
  done
  for host in $glab_hosts; do
    repo=$(glab api --hostname "$host" "projects/$(urlenc_path "$name")" 2>/dev/null) || continue
    [[ -n "$repo" ]] || continue
    add_candidate "$host" \
      "$(jq -r '.path_with_namespace' <<<"$repo")" "$(jq -r '.web_url' <<<"$repo")"
  done
else
  # --- 3. a bare name matches on the basename, exactly ------------------------
  want=$(lower "$name")
  collect() {  # <host> < tsv of "<project>\t<url>"
    local project url
    while IFS="$(printf '\t')" read -r project url; do
      [[ -n "$project" ]] || continue
      [[ "$(lower "${project##*/}")" == "$want" ]] || continue
      add_candidate "$1" "$project" "$url"
    done
  }
  for host in $gh_hosts; do
    collect "$host" < <(gh api --hostname "$host" --paginate \
      "/user/repos?per_page=100&affiliation=owner,collaborator,organization_member" \
      --jq '.[] | [.full_name, .html_url] | @tsv' 2>/dev/null || true)
  done
  for host in $glab_hosts; do
    collect "$host" < <(glab api --hostname "$host" \
      "projects?membership=true&simple=true&per_page=100&search=$name" 2>/dev/null \
      | jq -r '.[] | [.path_with_namespace, .web_url] | @tsv' 2>/dev/null || true)
  done
fi

count=$(jq 'length' <<<"$candidates")

if [[ "$count" -eq 0 ]]; then
  fall_back_to_cwd "no repo named '$name' on any authenticated forge; resolving from cwd"
  exit 0
fi

if [[ "$count" -gt 1 ]]; then
  echo "TARGET_VIA=ambiguous"
  echo "TARGET_CANDIDATES=$candidates"
  exit 0
fi

key=$(jq -r '.[0].key' <<<"$candidates")
emit_resolved "${key%%/*}" "${key#*/}" "$(jq -r '.[0].url' <<<"$candidates")"
