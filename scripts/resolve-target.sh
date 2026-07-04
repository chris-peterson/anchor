#!/usr/bin/env bash
# Resolve a *named* target repo to its forge facts through tack's repo database,
# so anchor's forge skills can operate on a repo by name instead of inferring it
# from the cwd's origin remote (which is only right when the cwd repo IS the
# target). Given `file an issue against <name>` / `open the MR in <name>`, the
# skill passes <name> here rather than guessing.
#
# tack is an *optional* dependency (as elsewhere in anchor): no tack on PATH, or
# no match, and this reports TARGET_VIA=cwd so the caller reproduces today's
# cwd/origin behavior. This only ever *adds* name→remote routing when an explicit
# name is in play; it never changes the no-name path.
#
# > tack repo db: `tack repo <name> --json` returns entries shaped
# >   { key: "<host>/<group…>/<repo>", url, names[], locals[] }
# > — a name→canonical-remote lookup, with known local checkouts when any exist.
#
# Usage:
#   resolve-target.sh <repo-name>
#
# Output (KEY=value on stdout):
#   TARGET_VIA=<tack|ambiguous|cwd>
#     tack       — exactly one match; the fields below are populated
#     ambiguous  — >1 match; TARGET_CANDIDATES holds them for the skill to prompt
#     cwd        — no tack, or no match; caller falls back to cwd/origin
#   TARGET_NOTE=<text>          why it fell back (present on the cwd path)
#   TARGET_CANDIDATES=<json>    [{key,url,local}] to disambiguate (ambiguous only)
#   TARGET_URL=<url>            canonical https remote           (tack only)
#   TARGET_FORGE=<github|gitlab|other>   picks the CLI            (tack only)
#   TARGET_HOST=<host>          e.g. gitlab.getty.cloud (glab --hostname) (tack only)
#   TARGET_PROJECT=<path>       full project path after the host, any depth
#                               (gh -R owner/repo · glab :fullpath / -R)  (tack only)
#   TARGET_LOCAL=<path>         locals[0], or empty when the repo has no known
#                               checkout — empty means remote-only: operations
#                               that read repo files or need a work tree must be
#                               degraded or handed an explicit --repo (tack only)

set -euo pipefail

name="${1:?usage: resolve-target.sh <repo-name>}"

# tack optional — without it there's no repo db to consult.
if ! command -v tack >/dev/null 2>&1; then
  echo "TARGET_VIA=cwd"
  echo "TARGET_NOTE=tack not on PATH; resolving from cwd"
  exit 0
fi

json=$(tack repo "$name" --json 2>/dev/null || true)
[[ -z "$json" ]] && json='[]'
count=$(jq 'length' <<<"$json" 2>/dev/null || echo 0)

if [[ "$count" -eq 0 ]]; then
  echo "TARGET_VIA=cwd"
  echo "TARGET_NOTE=no tack repo matched '$name'; resolving from cwd"
  exit 0
fi

if [[ "$count" -gt 1 ]]; then
  echo "TARGET_VIA=ambiguous"
  echo "TARGET_CANDIDATES=$(jq -c '[.[] | {key, url, local: (.locals[0] // "")}]' <<<"$json")"
  exit 0
fi

# Exactly one match — split the key into host + project path (the project path
# can be many segments deep on GitLab, e.g. group/subgroup/repo).
url=$(jq -r '.[0].url' <<<"$json")
key=$(jq -r '.[0].key' <<<"$json")
local=$(jq -r '.[0].locals[0] // ""' <<<"$json")
host="${key%%/*}"
project="${key#*/}"
case "$host" in
  *github.com*) forge=github ;;
  *gitlab*)     forge=gitlab ;;
  *)            forge=other ;;
esac

echo "TARGET_VIA=tack"
echo "TARGET_URL=$url"
echo "TARGET_FORGE=$forge"
echo "TARGET_HOST=$host"
echo "TARGET_PROJECT=$project"
echo "TARGET_LOCAL=$local"
