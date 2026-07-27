#!/usr/bin/env bash
# Build the per-file deep-link prefixes a CR description's Review guide points
# at, so the skill never assembles a 64-char path hash into a URL by hand.
#
# Each forge anchors a diff line as <view-path>#<hash-of-file-path><line-part>,
# where the hash is of the repo-relative path (GitLab sha1, GitHub sha256) and
# only the trailing line part is the author's choice. This emits everything up
# to that line part, per changed file:
#
#   FILE_LINKS=<json>   {path: "<CR_URL>/<view>#<anchor>"}
#
# The caller appends the line part (documented in guides/cr-formatting.md):
#   GitLab  <prefix>_<old-line>_<new-line>
#   GitHub  <prefix>R<new-line>     (L<old-line> for the left side)
# and uses the bare prefix for a file-level link.
#
# Usage:
#   deep-links.sh --forge <github|gitlab> --cr-url <url> --base <ref>
#
# Emits FILE_LINKS={} for a forge with no anchor scheme (`none`), a missing
# CR URL (the skill's skip-deep-links path), or a range with no changed files.

set -euo pipefail

forge=""
cr_url=""
base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge)  forge="${2:?--forge needs github|gitlab|none}"; shift 2 ;;
    --cr-url) cr_url="${2-}"; shift 2 ;;
    --base)   base="${2:?--base needs a ref}"; shift 2 ;;
    *) echo "deep-links.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# Hash a path with the given algorithm. `shasum` covers macOS, Windows Git Bash,
# and most Linux; the GNU coreutils names cover distros that ship those instead.
path_hash() {
  local algo="$1" path="$2"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$path" | shasum -a "$algo" | cut -d' ' -f1
  elif command -v "sha${algo}sum" >/dev/null 2>&1; then
    printf '%s' "$path" | "sha${algo}sum" | cut -d' ' -f1
  else
    echo "deep-links.sh: no sha${algo} tool found (shasum or sha${algo}sum)" >&2
    exit 69
  fi
}

case "$forge" in
  gitlab) algo=1;   view=diffs   ;;
  github) algo=256; view=changes ;;  # /changes, not /files — see cr-formatting.md
  *)      echo 'FILE_LINKS={}'; exit 0 ;;
esac

if [[ -z "$cr_url" || -z "$base" ]]; then
  echo 'FILE_LINKS={}'
  exit 0
fi

links='{}'
while read -r path; do
  [[ -z "$path" ]] && continue
  hash=$(path_hash "$algo" "$path")
  case "$forge" in
    gitlab) prefix="${cr_url}/${view}#${hash}" ;;
    github) prefix="${cr_url}/${view}#diff-${hash}" ;;
  esac
  links=$(jq -c --arg p "$path" --arg l "$prefix" '. + {($p): $l}' <<<"$links")
done < <(git diff --name-only "${base}...HEAD" 2>/dev/null || true)

echo "FILE_LINKS=$links"
