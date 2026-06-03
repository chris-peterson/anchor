#!/usr/bin/env bash
# Launch moor with a pre-populated MOOR_CONTEXT input section, then leave the
# context file in place so the caller can read the verdict back. moor reads
# input.{title,details} on launch and renders it as a header above the diff;
# the caller reads output.{exitCode,reviewer,rejections} from the same file
# after moor exits. Both modes print `MOOR_CONTEXT=<path>` on the last line —
# parse that path, then read its JSON `output` section.
#
# Range mode — review a git range through git difftool (--dir-diff):
#   bash moor-review.sh <diff-range>
#     e.g. bash moor-review.sh '@{upstream}...HEAD'   # commit review (single commit at HEAD)
#     e.g. bash moor-review.sh HEAD~1...HEAD          # commit review (single commit at HEAD)
#     e.g. bash moor-review.sh HEAD                   # preview (working tree vs HEAD)
#
# Files mode — review two arbitrary paths (no git range required), e.g. an old
# vs. proposed CR description. Domain-agnostic: pass the header text yourself.
#   bash moor-review.sh --files <left> <right> [--title <t>] [--detail label=value]...
#     e.g. bash moor-review.sh --files cur.md new.md \
#            --title 'CR description — proposed edits' \
#            --detail repo=anchor --detail branch=my-feature

set -euo pipefail

CACHE_DIR=~/.cache/moor
mkdir -p "$CACHE_DIR"
context_path="$CACHE_DIR/context-$$.json"

if [[ "${1:-}" == "--files" ]]; then
  shift
  left="${1:?Usage: moor-review.sh --files <left> <right> [--title <t>] [--detail label=value]...}"
  right="${2:?Usage: moor-review.sh --files <left> <right> [--title <t>] [--detail label=value]...}"
  shift 2

  title="Proposed changes"
  details_json='[]'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)  title="${2:?--title needs a value}"; shift 2 ;;
      --detail)
        pair="${2:?--detail needs label=value}"; shift 2
        details_json=$(jq -c --arg l "${pair%%=*}" --arg v "${pair#*=}" \
          '. + [{label:$l, value:$v}]' <<<"$details_json")
        ;;
      *) echo "moor-review.sh: unknown --files option: $1" >&2; exit 64 ;;
    esac
  done

  jq -n --arg t "$title" --argjson d "$details_json" \
    '{input: {title:$t, details:$d}}' > "$context_path"

  # moor exits 0/1/2/3 to signal the review outcome (clean / rejections /
  # unreviewed / closed early). The verdict the caller acts on lives in the
  # context file's output section, so don't let a non-zero exit abort here.
  # Requires moor >= 0.6.1, where two-file mode runs the full review (earlier
  # versions rendered a bare diff and always exited 3).
  moor --context "$context_path" "$left" "$right" || true

  echo "MOOR_CONTEXT=$context_path"
  exit 0
fi

diff_range="${1:?Usage: moor-review.sh <diff-range>  (or --files <left> <right> ...)}"

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
