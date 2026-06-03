#!/usr/bin/env bash
# Launch a visual diff review through git's configured difftool, then read the
# verdict back out and print it on stdout so the caller acts on a single
# command's output — no separate file read, no orchestration steps to narrate.
#
# The review feedback travels through a sidecar file named by the MOOR_CONTEXT
# env var — moor's contract: it reads input.{title,details} on launch (rendered
# as a header above the diff) and writes output.{exitCode,reviewer,rejections}
# on exit. This script pre-populates the input section, then prints:
#   REVIEW_VERDICT=<code>   output.exitCode — 0 clean / 1 rejections / 2 unreviewed
#                           / 3 closed early / "absent" if no output was written
#   REVIEW_OUTPUT=<json>    the compact output object (present when a verdict exists);
#                           read output.rejections from here on a 1 verdict
#
# Commit mode — review the just-made commit; the range is determined here:
#   bash review-diff.sh --commit
#     1 unpushed commit         -> @{upstream}...HEAD
#     2+ unpushed commits       -> HEAD~1...HEAD (prior commits already reviewed)
#     no upstream tracking      -> origin/HEAD (symbolic), then origin/main, then origin/master
#
# Range mode — review an explicit git range through git difftool (--dir-diff):
#   bash review-diff.sh <diff-range>
#     e.g. bash review-diff.sh HEAD                   # preview (working tree vs HEAD)
#     e.g. bash review-diff.sh HEAD~1...HEAD          # explicit commit range
#
# Files mode — review two arbitrary paths (no git range required), e.g. an old
# vs. proposed CR description. Domain-agnostic: pass the header text yourself.
#   bash review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...
#     e.g. bash review-diff.sh --files cur.md new.md \
#            --title 'CR description — proposed edits' \
#            --detail repo=anchor --detail branch=my-feature

set -euo pipefail

CACHE_DIR=~/.cache/moor
mkdir -p "$CACHE_DIR"
context_path="$CACHE_DIR/context-$$.json"

# Read the review outcome from the sidecar and print it on stdout, so the caller
# reads the verdict from this command's output instead of opening the file.
emit_verdict() {
  local output
  output=$(jq -c '.output // empty' "$context_path" 2>/dev/null || true)
  if [[ -z "$output" ]]; then
    echo "REVIEW_VERDICT=absent"
    return
  fi
  echo "REVIEW_VERDICT=$(jq -r '.exitCode // "absent"' <<<"$output")"
  echo "REVIEW_OUTPUT=$output"
}

# Determine the diff range for a commit review from the unpushed commit count.
# Pure git plumbing — kept here (not in the skill prose) so the @{u} brace token
# stays inside a script, where Claude Code's bash safety analyzer doesn't fire.
determine_commit_range() {
  local count
  count=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || true)
  if [[ -z "$count" ]]; then
    local origin_head
    origin_head=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$origin_head" ]] && git rev-parse --verify --quiet "$origin_head" >/dev/null; then
      echo "${origin_head}...HEAD"
    elif git rev-parse --verify --quiet origin/main >/dev/null; then
      echo "origin/main...HEAD"
    elif git rev-parse --verify --quiet origin/master >/dev/null; then
      echo "origin/master...HEAD"
    else
      return 1
    fi
  elif [[ "$count" -eq 1 ]]; then
    # 1 unpushed commit -> compare against upstream.
    echo '@{upstream}...HEAD'
  else
    # 2+ unpushed commits -> latest vs its parent (prior commits already reviewed).
    # 0 (HEAD already pushed, e.g. a message-only amend) -> same: latest vs parent.
    echo "HEAD~1...HEAD"
  fi
}

if [[ "${1:-}" == "--files" ]]; then
  shift
  left="${1:?Usage: review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...}"
  right="${2:?Usage: review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...}"
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
      *) echo "review-diff.sh: unknown --files option: $1" >&2; exit 64 ;;
    esac
  done

  jq -n --arg t "$title" --argjson d "$details_json" \
    '{input: {title:$t, details:$d}}' > "$context_path"

  # Two-file mode invokes moor directly (it isn't a git range, so git difftool
  # doesn't apply). moor exits 0/1/2/3 to signal the outcome (clean / rejections
  # / unreviewed / closed early); the verdict the caller acts on lives in the
  # sidecar's output section, so don't let a non-zero exit abort here. Requires
  # moor >= 0.6.1, where two-file mode runs the full review (earlier versions
  # rendered a bare diff and always exited 3).
  moor --context "$context_path" "$left" "$right" || true

  emit_verdict
  exit 0
fi

if [[ "${1:-}" == "--commit" ]]; then
  diff_range=$(determine_commit_range) || {
    echo "review-diff.sh: could not determine a diff range (no upstream tracking branch and no origin/main or origin/master)" >&2
    exit 65
  }
else
  diff_range="${1:?Usage: review-diff.sh --commit | <diff-range> | --files <left> <right> ...}"
fi

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

# moor reads the sidecar path from this env var when it's the configured difftool.
export MOOR_CONTEXT="$context_path"
# The verdict the caller acts on lives in the sidecar's output section, not the
# difftool exit code, so don't let a non-zero exit abort before emit_verdict.
git difftool --no-prompt --dir-diff "$diff_range" || true

emit_verdict
