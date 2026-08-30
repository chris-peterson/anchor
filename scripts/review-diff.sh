#!/usr/bin/env bash
# Dispatcher for anchor's visual diff review. Resolves the diff range and the
# header from the requested mode, selects the review backend, and delegates the
# launch-and-normalize to that backend's adapter, which prints the result on
# stdout so the caller acts on a single command's output:
#   REVIEW_VERDICT=<approved|changes-requested|incomplete|no-verdict>
#   REVIEW_OUTPUT=<normalized json>   (the DIFF contract; see SPEC.md "DIFF")
#
# The backend is `anchor.<skill>.reviewBackend` when the caller passed --skill,
# else `anchor.reviewBackend`, else the per-skill default in
# `skill_default_backend` — `editor` for the skills whose review is one drafted
# document, `revdiff` for the ones whose subject is a changeset. Each adapter
# lives in scripts/review/<backend>.sh and defines emit_review, mapping the
# tool's native output onto the normalized result. Range/header resolution is
# backend-agnostic and stays here.
#
# Three review modes, each named for what it shows:
#   --local      local changes — working tree vs the last commit (stages the
#                paths it was given first, so a new file is in the review):
#     bash review-diff.sh --local --path <p> [--path <p>...]   -> HEAD
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
#   A git-range review takes the same --title / --detail overrides as --files.
#   The computed header describes the *local* HEAD, which is the wrong subject
#   when the range is somebody else's change request fetched into this checkout
#   — /anchor:review passes the CR's own title and facts instead.
#
# Files mode — review two arbitrary paths (no git range required), e.g. an old
# vs. proposed CR description. Domain-agnostic: pass the header text yourself.
#   bash review-diff.sh --files <left> <right> [--title <t>] [--detail label=value]...

set -euo pipefail

# Context flags, accepted anywhere in the argv:
#   --repo <path>  retargets the git range / review onto a checkout other than
#     the cwd repo (see scripts/lib/resolve-context.sh). The --files mode takes
#     absolute paths, so this is only meaningful for the git-range modes.
#   --path <p>  a path for --local to stage, repeatable, resolved against the repo
#     root. Only these are staged: a whole-tree add would pull a session sharing
#     the checkout into this review (see scripts/lib/stage-paths.sh).
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
#       REVIEW_BACKEND_SOURCE=override|config|default
#       REVIEW_EDITOR=<command>            the editor an editor review opens
#       REVIEW_EDITOR_SOURCE=config|default
#         The last three say whether the tool about to open is one the user
#         chose, so a launch that coalesced onto a default can name the key that
#         would make it a choice (UX-07). REVIEW_EDITOR pair only when the
#         editor backend is what would run.
#       REVIEW_EDITOR_AVAILABLE=0|1        1 = --backend editor would reach an
#         editor. Reported on its own axis because it answers a different
#         question: not "which viewer shows the changeset" but "can the user be
#         handed the drafted artifact to edit" — the rung a skill offers when
#         the viewer is missing or died (see guides/review-fallback.md).
# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/review-editor.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-editor.sh"
# shellcheck source=lib/stage-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-paths.sh"
CTX_REPO=""
review_skill=""
backend_override=""
print_backend=0
stage_paths=()
# One pass over the whole argv, so a caller that writes `--repo` after the mode
# still retargets. These used to be leading-only: a `--repo` that arrived after
# the mode fell through to the mode parser, which collected it as an unnamed
# token and never read it, so the review silently ran against the cwd repo — and
# `--local` staged that repo — while the rest of the flow used the target.
# Flags whose value is arbitrary text pass through *with* their value, so a value
# that happens to look like a context flag is not read as one.
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --skill)    review_skill="${2:?--skill needs a name}"; shift 2 ;;
    --backend)  backend_override="${2:?--backend needs a name}"; shift 2 ;;
    --path)     stage_paths+=("${2:?--path needs a path}"); shift 2 ;;
    --print-backend) print_backend=1; shift ;;
    --title|--detail|--message-file)
                rest+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    *)          rest+=("$1"); shift ;;
  esac
done
set -- "${rest[@]+"${rest[@]}"}"
ctx_resolve_repo

# Which shape suits an artifact varies, so the default is per skill (CONFIG-15).
# A review whose subject is a changeset gets the diff viewer — that is what
# per-hunk annotation is for. A review whose subject is one drafted document
# gets the editor: its `--files` pair is text against text, so the diff viewer
# marks every line as added and asks the reviewer to comment their way to a
# rewrite, where the editor hands them the document and takes back what they
# saved.
skill_default_backend() {
  case "${1:-}" in
    prepare-review|issue|release) printf 'editor' ;;
    *)                            printf 'revdiff' ;;
  esac
}

# resolve_backend's answers, set rather than printed: a `$(...)` call would run
# the function in a subshell and drop the source along with it. The source is
# whether the name came from `--backend`, from a config key, or from the per-skill
# default — substitution reads it, since a preference the user typed is honored
# even when it cannot open and a default is not.
resolved_backend=""
resolved_backend_source=""

# The key resolves per skill first, the way anchor.<skill>.watchPipelineAfterPush
# does.
resolve_backend() {
  local b="$backend_override" src=override
  if [[ -z "$b" ]]; then
    src=config
    [[ -z "$review_skill" ]] || b=$(git config "anchor.${review_skill}.reviewBackend" 2>/dev/null || true)
    [[ -n "$b" ]] || b=$(git config anchor.reviewBackend 2>/dev/null || true)
  fi
  if [[ -z "$b" ]]; then
    src=default
    b=$(skill_default_backend "$review_skill")
  fi
  resolved_backend="$b"
  resolved_backend_source="$src"
}

# The editor backend opens whatever editor git resolves, so it has no binary of
# its own to look for; revdiff is named after its.
#
# This stays a PATH question on purpose. A *configured* editor backend that
# cannot reach an editor still belongs to the editor adapter, whose `no-verdict`
# names the missing piece — degrading it to a diff viewer would answer the diff
# question when the caller asked the artifact one. The sharper
# `anchor_editor_available` is asked where the decision is what to open or offer:
# `installed_backend` below, and the `--print-backend` probe.
backend_installed() {
  [[ "$1" == "editor" ]] || command -v "$1" >/dev/null 2>&1
}

# The resolved backend, or an installed one standing in for it. Nothing installed
# leaves the name as resolved — the probe reports that alongside
# REVIEW_BACKEND_AVAILABLE=0, so a caller still learns what was preferred.
#
# Substitution runs in both directions, and what it turns on is where the name
# came from rather than which name it is. A *configured* backend is kept whether
# or not it can open, so its own report names the missing piece: asking for the
# editor and getting a diff viewer answers a question the user didn't ask. A
# *defaulted* one is a choice nobody made, so an editor with nowhere to open
# gives way to an installed viewer rather than dead-ending a flow in a host
# problem the user was never warned about.
installed_backend() {
  local preferred="$1"
  if [[ "$preferred" == "editor" ]]; then
    if [[ "$resolved_backend_source" == "default" ]] \
       && ! anchor_editor_available && backend_installed revdiff; then
      printf '%s' revdiff; return
    fi
    printf '%s' editor; return
  fi
  if backend_installed "$preferred"; then printf '%s' "$preferred"; return; fi
  if backend_installed revdiff; then printf '%s' revdiff; return; fi
  printf '%s' "$preferred"
}

if [[ "$print_backend" == "1" ]]; then
  resolve_backend
  preferred="$resolved_backend"
  backend=$(installed_backend "$preferred")
  editor_available=0
  anchor_editor_available && editor_available=1
  echo "REVIEW_BACKEND=$backend"
  if [[ "$backend" == "editor" ]]; then
    # Selected, so its own reachability is the answer to "is anything usable
    # here" — a configured editor backend with nowhere to open an editor is as
    # unavailable as an absent viewer, and saying otherwise sends the caller to
    # launch a review that reports a host problem instead of showing anything.
    echo "REVIEW_BACKEND_AVAILABLE=$editor_available"
  elif backend_installed "$backend"; then
    echo "REVIEW_BACKEND_AVAILABLE=1"
  else
    echo "REVIEW_BACKEND_AVAILABLE=0"
  fi
  # What the preference named, reported only when the run would use something
  # else — a config key that named an absent viewer, or a defaulted editor with
  # nowhere to open. Either way the caller has a name to say out loud, so the
  # tool that opens isn't discovered as a surprise window.
  [[ "$backend" == "$preferred" ]] || echo "REVIEW_BACKEND_CONFIGURED=$preferred"
  # Whether the tool about to open is one the user chose. A review opens in
  # whatever anchor coalesced onto when nothing is configured, and the reviewer
  # has no way to tell that from the tool itself — so the launch names the key
  # that would make it a choice, and this is what tells it to (UX-07).
  echo "REVIEW_BACKEND_SOURCE=$resolved_backend_source"
  if [[ "$backend" == "editor" ]]; then
    echo "REVIEW_EDITOR=$(anchor_editor_resolve)"
    echo "REVIEW_EDITOR_SOURCE=$(anchor_editor_source)"
  fi
  echo "REVIEW_EDITOR_AVAILABLE=$editor_available"
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
  # Git-range modes: resolve the range and the header style. Header overrides
  # are collected first so they can be applied after the defaults are computed.
  override_title=""
  override_details_json=""
  args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)  override_title="${2:?--title needs a value}"; shift 2 ;;
      --detail)
        pair="${2:?--detail needs label=value}"; shift 2
        override_details_json=$(jq -c --arg l "${pair%%=*}" --arg v "${pair#*=}" \
          '. + [{label:$l, value:$v}]' <<<"${override_details_json:-[]}")
        ;;
      --commit|--local|--previous|--full|--message-file) args+=("$1"); shift ;;
      # A misspelled flag used to be collected here and dropped, which reads as a
      # review of something the caller didn't ask for; --files errors on one, so
      # the git-range modes do too.
      -*) echo "review-diff.sh: unknown option: $1" >&2; exit 64 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"

  # Each git-range mode takes exactly one token (--local optionally a
  # --message-file pair). Anything past that was meant to do something, and
  # dropping it reviews a different subject than the caller asked for.
  expect_consumed() {
    if [[ $# -gt 0 ]]; then
      echo "review-diff.sh: unexpected argument: $1" >&2
      exit 64
    fi
  }

  if [[ "${1:-}" == "--commit" ]]; then
    diff_range=$(determine_commit_range) || {
      echo "review-diff.sh: could not determine a diff range (no upstream tracking branch and no origin/main or origin/master)" >&2
      exit 65
    }
    header_mode="commit"
    expect_consumed "${@:2}"
  elif [[ "${1:-}" == "--local" ]]; then
    diff_range="HEAD"
    header_mode="local"
    # --message-file seeds the drafted commit message into the review so the
    # reviewer reviews it alongside the diff (and can edit it in-tool).
    if [[ "${2:-}" == "--message-file" ]]; then
      message_file="${3:?--message-file needs a path}"
      [[ -r "$message_file" ]] || { echo "review-diff.sh: message file not readable: $message_file" >&2; exit 66; }
      expect_consumed "${@:4}"
    else
      expect_consumed "${@:2}"
    fi
    # Staged last, so a rejected argv never leaves the repo staged. Only the
    # named paths: a new file has to be in the index to appear in a `git diff
    # HEAD`, and a whole-tree add to get it there would pull in a session sharing
    # the checkout (scripts/lib/stage-paths.sh).
    anchor_stage_paths "review-diff.sh" "${stage_paths[@]+"${stage_paths[@]}"}"
  elif [[ "${1:-}" == "--previous" ]]; then
    git rev-parse --verify --quiet HEAD~1 >/dev/null || {
      echo "review-diff.sh: HEAD has no parent commit to compare against" >&2
      exit 65
    }
    diff_range="HEAD~1...HEAD"
    header_mode="commit"
    expect_consumed "${@:2}"
  elif [[ "${1:-}" == "--full" ]]; then
    diff_range=$(determine_default_branch_range) || {
      echo "review-diff.sh: could not resolve a default branch (no origin/HEAD, origin/main, or origin/master)" >&2
      exit 65
    }
    header_mode="full"
    expect_consumed "${@:2}"
  else
    diff_range="${1:?Usage: review-diff.sh --local | --previous | --full | --commit | <diff-range> | --files <left> <right> ...}"
    if [[ "$diff_range" == "HEAD" ]]; then header_mode="local"; else header_mode="commit"; fi
    expect_consumed "${@:2}"
  fi

  repo=$(basename "$(git rev-parse --show-toplevel)")
  branch=$(git rev-parse --abbrev-ref HEAD)

  if [[ "$header_mode" == "local" ]]; then
    stat=$(git diff --cached --stat HEAD | tail -1 | sed 's/^[[:space:]]*//')
    base=$(git log -1 --format='%h %s' HEAD)
    if [[ -n "$message_file" ]]; then
      # Seed the drafted message: subject is the review's headline, the body row
      # is the message prose the backend renders, so message + diff are reviewed
      # together.
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

  # An override replaces the computed value rather than merging with it: the
  # computed header describes a different subject entirely, so keeping half of
  # it would attribute the range to the wrong commit.
  [[ -n "$override_title" ]] && review_title="$override_title"
  [[ -n "$override_details_json" ]] && review_details_json="$override_details_json"
fi

# --- Select the backend and delegate -----------------------------------------

# The resolved name is validated before substitution, so a typo in the config
# still fails loudly rather than being silently replaced by an installed viewer.
resolve_backend
backend="$resolved_backend"
adapter="$(dirname "${BASH_SOURCE[0]}")/review/${backend}.sh"
if [[ ! -r "$adapter" ]]; then
  echo "review-diff.sh: unknown review backend '$backend' (no adapter at $adapter). Set anchor.reviewBackend to editor or revdiff." >&2
  exit 64
fi
backend=$(installed_backend "$backend")
# A machine with no viewer installed keeps the configured adapter, whose report
# names the tool that is missing. There is nothing below it to degrade into —
# git's difftool is not a backend (DIFF-18) because a changeset shown without a
# verdict invites "you saw it, approve?", which is the rubber stamp the contract
# exists to prevent. The skill's fallback ladder (guides/review-fallback.md) is
# the rung below.
adapter="$(dirname "${BASH_SOURCE[0]}")/review/${backend}.sh"

# An empty range has nothing to show, and a viewer opened on nothing is quit the
# same way an approved review is — so launching one manufactures an `approved`
# for a changeset nobody saw. Report `no-verdict` naming the repo the range
# resolved against, which is also what surfaces a review pointed at the wrong
# checkout (DIFF-21).
if [[ "$review_mode" == "range" ]] && git diff --quiet "$diff_range" -- 2>/dev/null; then
  echo "review-diff.sh: $diff_range is empty in $(git rev-parse --show-toplevel) (target resolved via ${RESOLVED_VIA:-cwd}) — nothing to review" >&2
  jq -cn --arg b "$backend" --arg r "$diff_range" '{
    backend:$b, verdict:"no-verdict",
    reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
    capabilities:{producesVerdict:false, perHunkReview:false,
                  editableCommitMessage:false, editableDescription:false,
                  sideMarkers:false},
    raw:{exitCode:"empty-range", range:$r}}' \
    | { read -r out; echo "REVIEW_VERDICT=no-verdict"; echo "REVIEW_OUTPUT=$out"; }
  exit 0
fi

# The review-request contract the sourced adapter reads. Exported so the
# adapter (sourced below) counts as a consumer — it runs in this same shell.
export review_mode diff_range files_left files_right review_title review_details_json
export message_file review_skill

# shellcheck source=/dev/null
source "$adapter"
emit_review
