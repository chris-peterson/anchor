#!/usr/bin/env bash
# Launch moor dir-diff with a pre-populated MOOR_CONTEXT input section.
# moor reads input.{title,details} on launch and renders it as a header
# above the diff; the caller reads output.{exitCode,reviewer,rejections}
# from the same file after git difftool returns.
#
# Usage: bash moor-review.sh <diff-range>
#   e.g. bash moor-review.sh '@{upstream}...HEAD'   # commit review (single commit at HEAD)
#   e.g. bash moor-review.sh HEAD~1...HEAD          # commit review (single commit at HEAD)
#   e.g. bash moor-review.sh HEAD                   # preview (working tree vs HEAD)

set -euo pipefail

diff_range="${1:?Usage: moor-review.sh <diff-range>}"

CACHE_DIR=~/.cache/moor
mkdir -p "$CACHE_DIR"
context_path="$CACHE_DIR/context-$$.json"

repo=$(basename "$(git rev-parse --show-toplevel)")
branch=$(git rev-parse --abbrev-ref HEAD)

if [[ "$diff_range" == "HEAD" ]]; then
  # Preview: working tree vs HEAD, no specific commit. "on top of" names the
  # commit the working tree sits on, so "vs HEAD" is concrete.
  stat=$(git diff --cached --stat HEAD | tail -1 | sed 's/^[[:space:]]*//')
  base=$(git log -1 --format='%h %s' HEAD)
  title="Local changes vs HEAD"
  details_json=$(jq -n \
    --arg repo "$repo" \
    --arg br "$branch" \
    --arg base "$base" \
    --arg s "$stat" \
    '[
      {label:"repo",      value:$repo},
      {label:"branch",    value:$br},
      {label:"on top of", value:$base},
      {label:"summary",   value:$s}
    ]')
else
  # Commit review: HEAD is the target commit
  subject=$(git log -1 --format=%s HEAD)
  body=$(git log -1 --format=%b HEAD)
  hash=$(git log -1 --format=%h HEAD)
  author=$(git log -1 --format='%an <%ae>' HEAD)
  title="$subject"
  details_json=$(jq -n \
    --arg repo "$repo" \
    --arg br "$branch" \
    --arg c "$hash" \
    --arg a "$author" \
    --arg b "$body" \
    --arg r "$diff_range" \
    '[
      {label:"repo",   value:$repo},
      {label:"branch", value:$br},
      {label:"commit", value:$c},
      {label:"author", value:$a},
      {label:"range",  value:$r}
    ] + (if $b == "" then [] else [{label:"body", value:$b}] end)')
fi

jq -n --arg t "$title" --argjson d "$details_json" \
  '{input: {title:$t, details:$d}}' > "$context_path"

export MOOR_CONTEXT="$context_path"
git difftool --no-prompt --dir-diff "$diff_range"

echo "MOOR_CONTEXT=$context_path"
