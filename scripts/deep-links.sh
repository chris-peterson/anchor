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
#   deep-links.sh --verify <draft.md> --forge … --cr-url … --base …
#
# Emits FILE_LINKS={} for a forge with no anchor scheme (`none`), a missing
# CR URL (the skill's skip-deep-links path), or a range with no changed files.
#
# --verify checks the half this script does *not* own. The prefix is derived, so
# it is right by construction; the line part is the author's, read off the diff
# by hand, and a wrong one still resolves — the forge just scrolls to a line the
# bullet isn't describing. Nothing about the rendered link says it drifted. So
# verify reads each line part back against the working tree and reports:
#
#   out-of-range    the line is past the end of the file
#   blank-line      the target line is empty
#   unchanged-line  the line exists but isn't in a changed hunk of base...HEAD
#   unknown-file    an anchor whose hash matches no file in the range
#
# It cannot catch a link that landed on the wrong *changed* line — only the
# author knows which one was meant. Emits DEEP_LINK_SUSPECTS=<n> and exits 1
# when any are found, 0 when the draft is clean.

set -euo pipefail

forge=""
cr_url=""
base=""
verify=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge)  forge="${2:?--forge needs github|gitlab|none}"; shift 2 ;;
    --cr-url) cr_url="${2-}"; shift 2 ;;
    --base)   base="${2:?--base needs a ref}"; shift 2 ;;
    --verify) verify="${2:?--verify needs a draft file}"; shift 2 ;;
    *) echo "deep-links.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# Hash a path with the given algorithm. Neither name is available everywhere:
# macOS ships `shasum` and no `sha1sum`, Windows Git Bash ships `sha1sum` /
# `sha256sum` and no `shasum`, and distros vary. Try both before giving up.
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
declare -a paths=() prefixes=()
while read -r path; do
  [[ -z "$path" ]] && continue
  hash=$(path_hash "$algo" "$path")
  case "$forge" in
    gitlab) prefix="${cr_url}/${view}#${hash}" ;;
    github) prefix="${cr_url}/${view}#diff-${hash}" ;;
  esac
  links=$(jq -c --arg p "$path" --arg l "$prefix" '. + {($p): $l}' <<<"$links")
  paths+=("$path")
  prefixes+=("$prefix")
done < <(git diff --name-only "${base}...HEAD" 2>/dev/null || true)

if [[ -z "$verify" ]]; then
  echo "FILE_LINKS=$links"
  exit 0
fi

[[ -r "$verify" ]] || { echo "deep-links.sh: cannot read draft: $verify" >&2; exit 66; }

# Line *content* is read from the working tree; the changed-line set comes from
# base...HEAD. Those agree only on a clean tree — uncommitted edits shift content
# out from under the hunk set and every line past them reports as unchanged. The
# skill runs this after its STATE=match check, so a dirty tree here means the
# caller skipped that; say so rather than emit confident nonsense.
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "deep-links.sh: working tree is dirty — line numbers are checked against" >&2
  echo "  it while changed hunks come from ${base}...HEAD, so results will be off." >&2
  echo "DEEP_LINK_TREE=dirty"
fi

# New-side line numbers touched in base...HEAD, one per line. A `+c,0` hunk is a
# pure deletion and contributes none.
changed_lines() {
  git diff -U0 --no-color "${base}...HEAD" -- "$1" 2>/dev/null \
    | awk '/^@@/ {
        match($0, /\+[0-9]+(,[0-9]+)?/)
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        n = split(spec, a, ",")
        count = (n > 1 ? a[2] : 1)
        for (i = 0; i < count; i++) print a[1] + i
      }'
}

# Escape a literal prefix for use in a basic regular expression.
bre_escape() { printf '%s' "$1" | sed 's/[][\.*^$\\/]/\\&/g'; }

suspects=0
report() { echo "SUSPECT $1 $2:$3 $4"; suspects=$((suspects + 1)); }

for i in "${!paths[@]}"; do
  path="${paths[$i]}"
  prefix="${prefixes[$i]}"
  esc=$(bre_escape "$prefix")

  # Only the new side is checkable — the old side's content isn't in the tree.
  case "$forge" in
    github) refs=$(grep -o "${esc}R[0-9]\{1,\}" "$verify" | sed 's/.*R//' || true) ;;
    gitlab) refs=$(grep -o "${esc}_[0-9]\{1,\}_[0-9]\{1,\}" "$verify" | sed 's/.*_//' || true) ;;
  esac
  [[ -z "$refs" ]] && continue

  total=$(wc -l < "$path" | tr -d ' ')
  touched=$(changed_lines "$path")

  while read -r n; do
    [[ -z "$n" ]] && continue
    if (( n > total )); then
      report out-of-range "$path" "$n" "file has $total lines"
    elif [[ -z "$(sed -n "${n}p" "$path" | tr -d '[:space:]')" ]]; then
      report blank-line "$path" "$n" "target line is empty"
    elif ! grep -qx "$n" <<<"$touched"; then
      report unchanged-line "$path" "$n" "not in a changed hunk of ${base}...HEAD"
    fi
  done <<<"$refs"
done

# Anchors in the draft that belong to no file in the range at all.
case "$forge" in
  github) anchor_re='#diff-[0-9a-f]\{64\}' ;;
  gitlab) anchor_re='#[0-9a-f]\{40\}' ;;
esac
while read -r anchor; do
  [[ -z "$anchor" ]] && continue
  found=""
  for prefix in "${prefixes[@]}"; do
    [[ "$prefix" == *"$anchor" ]] && { found=1; break; }
  done
  [[ -n "$found" ]] || report unknown-file "$anchor" 0 "matches no file changed in ${base}...HEAD"
done < <(grep -o "$anchor_re" "$verify" | sort -u || true)

echo "DEEP_LINK_SUSPECTS=$suspects"
[[ "$suspects" -eq 0 ]]
