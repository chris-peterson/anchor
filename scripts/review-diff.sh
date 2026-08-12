#!/usr/bin/env bash
# Dispatcher for anchor's visual diff review. Resolves the diff range and the
# header from the requested mode, selects the review backend, and delegates the
# launch-and-normalize to that backend's adapter, which prints the result on
# stdout so the caller acts on a single command's output:
#   REVIEW_VERDICT=<approved|changes-requested|incomplete|no-verdict>
#   REVIEW_OUTPUT=<normalized json>   (the DIFF contract; see SPEC.md "DIFF")
#
# The backend is `anchor.<skill>.reviewBackend` when the caller passed --skill,
# else `anchor.reviewBackend` (default `revdiff`); each adapter lives in
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
#       edit it in-tool; the edit comes back as editedFields (see SPEC.md "DIFF").
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

# Leading flags, before the mode:
#   --repo / --worktree <path>  retargets the git range / difftool onto a
#     checkout other than the cwd repo (see scripts/lib/resolve-context.sh). The
#     --files mode takes absolute paths, so this is only meaningful for the
#     git-range modes.
#   --skill <name>  names the invoking skill, which selects the backend
#     (anchor.<skill>.reviewBackend over anchor.reviewBackend) and tells an
#     adapter which artifact is under review.
#   --backend <name>  drive this backend, ignoring the config keys — what a
#     caller passes back after probing with --print-backend, so the review runs
#     in the tool the probe said was there.
#   --print-backend  report which backend a review would run in, and exit
#     without launching anything — the probe a skill runs before deciding
#     whether a visual review is available at all. It considers only *installed*
#     tools, so what it names is something the caller can actually open:
#       REVIEW_BACKEND=<name>              what to pass to --backend
#       REVIEW_BACKEND_AVAILABLE=0|1       0 = nothing usable is installed
#       REVIEW_BACKEND_CONFIGURED=<name>   only when config asked for another
# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
CTX_REPO=""
CTX_WORKTREE=""
review_skill=""
backend_override=""
print_backend=0
while true; do
  case "${1:-}" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
    --skill)    review_skill="${2:?--skill needs a name}"; shift 2 ;;
    --backend)  backend_override="${2:?--backend needs a name}"; shift 2 ;;
    --print-backend) print_backend=1; shift ;;
    *) break ;;
  esac
done
ctx_resolve_repo

# Which shape suits an artifact varies — a commit message is a natural editor
# artifact, a CR description whose deep links want checking against the diff
# reads better in a diff viewer — so the key resolves per skill first, the way
# anchor.<skill>.watchPipelineAfterPush does.
resolve_backend() {
  local b="$backend_override"
  [[ -n "$b" || -z "$review_skill" ]] || b=$(git config "anchor.${review_skill}.reviewBackend" 2>/dev/null || true)
  [[ -n "$b" ]] || b=$(git config anchor.reviewBackend 2>/dev/null || true)
  printf '%s' "${b:-revdiff}"
}

# The editor backend opens whatever editor git resolves, so it has no binary of
# its own to look for; the others are named after theirs.
backend_installed() {
  [[ "$1" == "editor" ]] || command -v "$1" >/dev/null 2>&1
}

# The configured backend, or an installed viewer standing in for it. Nothing
# installed leaves the name as configured — the probe reports that alongside
# REVIEW_BACKEND_AVAILABLE=0, so a caller still learns what was asked for.
#
# Substitution stays among the diff viewers. `editor` remains selectable but
# never automatic: it edits one drafted artifact rather than showing a
# changeset, so standing in for an absent revdiff would answer a different
# question than the caller asked.
installed_backend() {
  local configured="$1" candidate
  if backend_installed "$configured"; then printf '%s' "$configured"; return; fi
  for candidate in revdiff moor; do
    if backend_installed "$candidate"; then printf '%s' "$candidate"; return; fi
  done
  printf '%s' "$configured"
}

if [[ "$print_backend" == "1" ]]; then
  configured=$(resolve_backend)
  backend=$(installed_backend "$configured")
  echo "REVIEW_BACKEND=$backend"
  if backend_installed "$backend"; then
    echo "REVIEW_BACKEND_AVAILABLE=1"
  else
    echo "REVIEW_BACKEND_AVAILABLE=0"
  fi
  [[ "$backend" == "$configured" ]] || echo "REVIEW_BACKEND_CONFIGURED=$configured"
  exit 0
fi

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

# The configured name is validated before substitution, so a typo in the config
# still fails loudly rather than being silently replaced by an installed viewer.
backend=$(resolve_backend)
adapter="$(dirname "${BASH_SOURCE[0]}")/review/${backend}.sh"
if [[ ! -r "$adapter" ]]; then
  echo "review-diff.sh: unknown review backend '$backend' (no adapter at $adapter). Set anchor.reviewBackend to editor, git, moor, or revdiff." >&2
  exit 64
fi
backend=$(installed_backend "$backend")
# A machine with no viewer installed reviews through the `git` adapter, which
# drives `git difftool --dir-diff` so the diff still opens in whatever tool git
# resolves. Only when git has one: with `diff.tool` and `merge.tool` both unset,
# `git difftool` falls back to vimdiff, which blocks forever where there is no
# terminal to answer it. Absent that, keep the configured adapter — it names the
# tool that is missing, which is more use than a generic no-verdict.
if ! backend_installed "$backend" && \
   { git config --get diff.tool >/dev/null 2>&1 || git config --get merge.tool >/dev/null 2>&1; }; then
  backend=git
fi
adapter="$(dirname "${BASH_SOURCE[0]}")/review/${backend}.sh"

# The review-request contract the sourced adapter reads. Exported so the
# adapter (sourced below) counts as a consumer — it runs in this same shell.
export review_mode diff_range files_left files_right review_title review_details_json
export message_file review_skill

# shellcheck source=/dev/null
source "$adapter"
emit_review
