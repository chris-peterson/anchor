#!/usr/bin/env bash
# Dispatcher for anchor's visual diff review. Resolves the diff range and the
# header from the requested mode, selects the review backend, and delegates the
# launch-and-normalize to that backend's adapter, which prints the result on
# stdout so the caller acts on a single command's output:
#   REVIEW_VERDICT=<approved|changes-requested|incomplete|no-verdict>
#   REVIEW_OUTPUT=<normalized json>   (the REV contract; see SPEC.md "REV")
#
# The backend is `anchor.reviewBackend` (default `moor`); each adapter lives in
# scripts/review/<backend>.sh and defines emit_review, mapping the tool's native
# output onto the normalized result. Range/header resolution is backend-agnostic
# and stays here.
#
# Three review modes, each named for what it shows:
#   --local      local changes — working tree vs the last commit (stages first):
#     bash review-diff.sh --local       -> HEAD
#     bash review-diff.sh --local --message-file <path>
#       also seeds the drafted commit message (subject as headline, body as prose)
#       into the review, so the reviewer reviews the message with the diff and can
#       edit it in-tool; the edit comes back as editedFields (see SPEC.md "REV").
#   --previous   previous changeset — the last commit vs its parent:
#     bash review-diff.sh --previous    -> HEAD~1...HEAD
#   --full       full diff — the whole branch vs the default branch, the way a
#                reviewer sees a CR/MR/PR:
#     bash review-diff.sh --full        -> origin/HEAD (symbolic), else
#                                          origin/main, else origin/master ...HEAD
#
# Commit mode — review the just-made commit; the range is determined here:
#   bash review-diff.sh --commit
#     1 unpushed commit         -> @{upstream}...HEAD
#     2+ unpushed commits       -> HEAD~1...HEAD (prior commits already reviewed)
#     no upstream tracking      -> origin/HEAD (symbolic), then origin/main, then origin/master
#
# Range mode — review an explicit git range:
#   bash review-diff.sh <diff-range>
#     e.g. bash review-diff.sh HEAD                   # working tree vs HEAD
#     e.g. bash review-diff.sh HEAD~1...HEAD          # explicit commit range
#
# Files mode — review two arbitrary paths (no git range required), e.g. an old
# vs. proposed CR description. Domain-agnostic: pass the header text yourself.
#   bash review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...

set -euo pipefail

# --repo / --worktree <path> (leading, before the mode) retargets the git range /
# difftool onto a checkout other than the cwd repo (see
# scripts/lib/resolve-context.sh). The --files mode takes absolute paths, so this
# is only meaningful for the git-range modes.
# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
CTX_REPO=""
CTX_WORKTREE=""
case "${1:-}" in
  --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
  --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
esac
ctx_resolve_repo

# Resolve "the whole branch vs the default branch" range. Tries the symbolic
# origin/HEAD first, then the conventional origin/main and origin/master.
# Pure git plumbing — kept in a script so the brace tokens don't trip Claude
# Code's bash safety analyzer from skill prose.
determine_default_branch_range() {
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
}

# Determine the diff range for a commit review from the unpushed commit count.
determine_commit_range() {
  local count
  count=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || true)
  if [[ -z "$count" ]]; then
    determine_default_branch_range
  elif [[ "$count" -eq 1 ]]; then
    echo '@{upstream}...HEAD'
  else
    echo "HEAD~1...HEAD"
  fi
}

# --- Resolve the review request (mode-agnostic vars the adapter reads) --------

review_mode="range"
files_left=""
files_right=""
diff_range=""
header_mode=""
review_title=""
review_details_json="[]"
message_file=""

if [[ "${1:-}" == "--files" ]]; then
  review_mode="files"
  shift
  files_left="${1:?Usage: review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...}"
  files_right="${2:?Usage: review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...}"
  shift 2
  review_title="Proposed changes"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)  review_title="${2:?--title needs a value}"; shift 2 ;;
      --detail)
        pair="${2:?--detail needs label=value}"; shift 2
        review_details_json=$(jq -c --arg l "${pair%%=*}" --arg v "${pair#*=}" \
          '. + [{label:$l, value:$v}]' <<<"$review_details_json")
        ;;
      *) echo "review-diff.sh: unknown --files option: $1" >&2; exit 64 ;;
    esac
  done
else
  # Git-range modes: resolve the range and the header style.
  if [[ "${1:-}" == "--commit" ]]; then
    diff_range=$(determine_commit_range) || {
      echo "review-diff.sh: could not determine a diff range (no upstream tracking branch and no origin/main or origin/master)" >&2
      exit 65
    }
    header_mode="commit"
  elif [[ "${1:-}" == "--local" ]]; then
    git add -A
    diff_range="HEAD"
    header_mode="local"
    # --message-file seeds the drafted commit message into the review so the
    # reviewer reviews it alongside the diff (and can edit it in-tool).
    if [[ "${2:-}" == "--message-file" ]]; then
      message_file="${3:?--message-file needs a path}"
      [[ -r "$message_file" ]] || { echo "review-diff.sh: message file not readable: $message_file" >&2; exit 66; }
    fi
  elif [[ "${1:-}" == "--previous" ]]; then
    git rev-parse --verify --quiet HEAD~1 >/dev/null || {
      echo "review-diff.sh: HEAD has no parent commit to compare against" >&2
      exit 65
    }
    diff_range="HEAD~1...HEAD"
    header_mode="commit"
  elif [[ "${1:-}" == "--full" ]]; then
    diff_range=$(determine_default_branch_range) || {
      echo "review-diff.sh: could not resolve a default branch (no origin/HEAD, origin/main, or origin/master)" >&2
      exit 65
    }
    header_mode="full"
  else
    diff_range="${1:?Usage: review-diff.sh --local | --previous | --full | --commit | <diff-range> | --files <left> <right> ...}"
    if [[ "$diff_range" == "HEAD" ]]; then header_mode="local"; else header_mode="commit"; fi
  fi

  repo=$(basename "$(git rev-parse --show-toplevel)")
  branch=$(git rev-parse --abbrev-ref HEAD)

  if [[ "$header_mode" == "local" ]]; then
    stat=$(git diff --cached --stat HEAD | tail -1 | sed 's/^[[:space:]]*//')
    base=$(git log -1 --format='%h %s' HEAD)
    if [[ -n "$message_file" ]]; then
      # Seed the drafted message: subject is the headline (moor's title), the
      # body row is the message prose moor renders and seeds its editable
      # message from (IM.IN-02 / CO-10), so message + diff are reviewed together.
      review_title=$(head -1 "$message_file")
      msg_body=$(tail -n +3 "$message_file")
      review_details_json=$(jq -n \
        --arg repo "$repo" --arg br "$branch" --arg base "$base" --arg s "$stat" --arg body "$msg_body" \
        '[{label:"repo",value:$repo},{label:"branch",value:$br},
          {label:"on top of",value:$base},{label:"summary",value:$s}]
         + (if $body == "" then [] else [{label:"body",value:$body}] end)')
    else
      review_title="Local changes vs HEAD"
      review_details_json=$(jq -n \
        --arg repo "$repo" --arg br "$branch" --arg base "$base" --arg s "$stat" \
        '[{label:"repo",value:$repo},{label:"branch",value:$br},
          {label:"on top of",value:$base},{label:"summary",value:$s}]')
    fi
  elif [[ "$header_mode" == "full" ]]; then
    base_ref="${diff_range%%...*}"
    count=$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "?")
    review_title="Full diff vs ${base_ref}"
    review_details_json=$(jq -n \
      --arg repo "$repo" --arg br "$branch" --arg base "$base_ref" \
      --arg r "$diff_range" --arg n "$count" \
      '[{label:"repo",value:$repo},{label:"branch",value:$br},
        {label:"base",value:$base},{label:"range",value:$r},{label:"commits",value:$n}]')
  else
    subject=$(git log -1 --format=%s HEAD)
    body=$(git log -1 --format=%b HEAD)
    hash=$(git log -1 --format=%h HEAD)
    author=$(git log -1 --format='%an <%ae>' HEAD)
    review_title="$subject"
    review_details_json=$(jq -n \
      --arg repo "$repo" --arg br "$branch" --arg c "$hash" \
      --arg a "$author" --arg b "$body" --arg r "$diff_range" \
      '[{label:"repo",value:$repo},{label:"branch",value:$br},
        {label:"commit",value:$c},{label:"author",value:$a},{label:"range",value:$r}]
       + (if $b == "" then [] else [{label:"body",value:$b}] end)')
  fi
fi

# --- Select the backend and delegate -----------------------------------------

backend=$(git config anchor.reviewBackend 2>/dev/null || true)
backend="${backend:-moor}"
adapter="$(dirname "${BASH_SOURCE[0]}")/review/${backend}.sh"
if [[ ! -r "$adapter" ]]; then
  echo "review-diff.sh: unknown review backend '$backend' (no adapter at $adapter). Set anchor.reviewBackend to moor or revdiff." >&2
  exit 64
fi

# The review-request contract the sourced adapter reads. Exported so the
# adapter (sourced below) counts as a consumer — it runs in this same shell.
export review_mode diff_range files_left files_right review_title review_details_json

# shellcheck source=/dev/null
source "$adapter"
emit_review
