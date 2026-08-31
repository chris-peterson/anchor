#!/usr/bin/env bash
# Dispatcher for anchor's visual diff review. Resolves the diff range and the
# header from the requested mode, selects the review backend, and delegates the
# launch-and-normalize to that backend's adapter, which prints the result on
# stdout so the caller acts on a single command's output:
#   REVIEW_VERDICT=<approved|changes-requested|incomplete|no-verdict>
#   REVIEW_OUTPUT=<normalized json>   (the DIFF contract; see SPEC.md "DIFF")
#
# The mode follows the subject: `edit` where the review is one file with no prior
# version, `diff` everywhere else. Adapters live in scripts/review/, one per mode,
# and each defines emit_review; a diff tool's own half lives under
# scripts/review/backends/. Range/header resolution is mode-agnostic and stays
# here.
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
# A review is resolved on two axes, and they are not the same question:
#
#   mode     the shape the review takes — `edit` or `diff`. The subject decides
#            it (subject_default_mode); there is no key, because the shape that
#            fits is a property of what is being reviewed rather than a taste.
#   backend  the tool that runs that mode, and the half that *is* a taste:
#            `anchor.edit.backend` names the editor (else git's chain),
#            `anchor.diff.backend` the viewer (else git's own `diff.tool`, else
#            revdiff). A mode can grow more backends without touching the mode
#            question.
#
#   --skill <name>  tells an adapter which artifact is under review. It does not
#     pick the mode — the subject does, always.
#   --mode <edit|diff>  run this mode rather than the one the subject picks —
#     what a caller passes back after probing, so the review opens in the shape
#     the probe said was reachable.
#   --backend <name>  run this tool within the mode, ignoring the config key.
#   --probe  report how a review would resolve, and exit without launching
#     anything — what a skill asks before deciding whether a visual review is
#     available at all. Pass it the same mode flag and paths as the launch: the
#     default reads the subject, so a bare probe on a `--files` review answers
#     for a review nobody is about to open. It considers only tools that can
#     actually open:
#       REVIEW_MODE=edit|diff              what to pass to --mode
#       REVIEW_MODE_SOURCE=override|config|subject
#       REVIEW_MODE_CONFIGURED=<mode>      only when the run uses another
#       REVIEW_BACKEND=<command>           the tool that will open — an editor
#         in `edit` mode, a viewer in `diff`
#       REVIEW_BACKEND_SOURCE=override|config|default
#       REVIEW_BACKEND_CONFIGURED=<name>   only when a named viewer was replaced
#       REVIEW_AVAILABLE=0|1               0 = this mode cannot open here
#         The SOURCE pair says whether what is about to open is something the
#         user chose, so a launch that coalesced onto a default can name the key
#         that would make it a choice (UX-07).
#       REVIEW_EDIT_AVAILABLE=0|1          1 = --mode edit would reach an
#         editor. Reported on its own axis because it answers a different
#         question: not "which viewer shows the changeset" but "can the user be
#         handed the drafted artifact to edit" — the rung a skill offers when
#         the viewer is missing or died (see guides/review-fallback.md).
# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/review-editor.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-editor.sh"
# shellcheck source=lib/review-difftool.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-difftool.sh"
# shellcheck source=lib/stage-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-paths.sh"
CTX_REPO=""
review_skill=""
mode_override=""
backend_override=""
probe_only=0
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
    --mode)     mode_override="${2:?--mode needs edit or diff}"; shift 2 ;;
    --backend)  backend_override="${2:?--backend needs a name}"; shift 2 ;;
    --path)     stage_paths+=("${2:?--path needs a path}"); shift 2 ;;
    --probe)    probe_only=1; shift ;;
    --title|--detail|--message-file)
                rest+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    *)          rest+=("$1"); shift ;;
  esac
done
set -- "${rest[@]+"${rest[@]}"}"
ctx_resolve_repo

# What the review is about, read off argv here because the probe answers before
# the subject parsers run and those parsers shift argv away.
subject_flag="${1:-}"
subject_left=""
[[ "$subject_flag" != "--files" ]] || subject_left="${2:-}"

# The mode default turns on one question: has this review got a diff to show
# (CONFIG-15)?
#
# A `--files` review with an empty left side is one file with no prior version —
# every line of it new. A viewer marks the whole thing as added and asks the
# reviewer to comment their way to a rewrite of a document an editor could have
# handed them, so that case takes `edit`. Everything else names a base to compare
# against — a left side with text in it, or a git range — and per-hunk annotation
# on real hunks is what `diff` is for.
subject_default_mode() {
  [[ "$subject_flag" == "--files" ]] || { printf 'diff'; return; }
  # Whitespace counts as empty: a `> file` that captured an absent description
  # leaves a newline, and one newline is not a prior version.
  if [[ -n "$subject_left" ]] && grep -q '[^[:space:]]' "$subject_left" 2>/dev/null; then
    printf 'diff'
  else
    printf 'edit'
  fi
}

# The superseded key, reported once. `anchor.reviewBackend` held a mode and a
# tool in one slot — `editor` named a shape, `revdiff` a program. The shape is
# not configurable at all now, and the tool has a key per mode, so there is
# nothing here to read the old value into. Say so rather than ignoring it, and
# remove this once nobody is on it.
report_superseded_key() {
  local legacy=""
  [[ -z "$review_skill" ]] || legacy=$(git config "anchor.${review_skill}.reviewBackend" 2>/dev/null || true)
  [[ -n "$legacy" ]] || legacy=$(git config anchor.reviewBackend 2>/dev/null || true)
  [[ -n "$legacy" ]] || return 0
  echo "review-diff.sh: anchor.reviewBackend ('$legacy') no longer does anything. The review's shape now follows what it is reviewing, and the tool is anchor.edit.backend (an editor) or anchor.diff.backend (a viewer)." >&2
}

# Resolution answers are set rather than printed: a `$(...)` call would run the
# function in a subshell and drop the source along with it. The source is where
# the name came from, and substitution reads it — a tool the user typed is
# honored even when it cannot open, where one anchor picked is not.
resolved_mode=""
resolved_mode_source=""
resolved_backend=""
resolved_backend_source=""

# The mode has no key. Which shape fits is a property of the review — one file
# with nothing to compare against has no diff to show — so reading it off the
# subject is the answer, and a key would only let a user ask for the shape that
# does not fit. A probe therefore has to be given the same subject the launch
# will get, or it answers a different review's question. `--mode` stays, since
# that is how a probe hands its answer to the launch.
resolve_mode() {
  if [[ -n "$mode_override" ]]; then
    resolved_mode="$mode_override"
    resolved_mode_source=override
    return
  fi
  resolved_mode=$(subject_default_mode)
  resolved_mode_source=subject
}

# Which tool runs the resolved mode — the half that is a preference, so each mode
# has one key for it. `edit` falls through to git's own editor chain and anchor's
# rungs past it (scripts/lib/review-editor.sh); `diff` falls through to revdiff.
resolve_backend() {
  local b="$backend_override"
  if [[ "$resolved_mode" == "edit" ]]; then
    if [[ -n "$b" ]]; then
      resolved_backend="$b"; resolved_backend_source=override; return
    fi
    resolved_backend=$(anchor_editor_resolve)
    resolved_backend_source=$(anchor_editor_source)
    return
  fi
  local src=override
  if [[ -z "$b" ]]; then
    src=config
    b=$(git config anchor.diff.backend 2>/dev/null || true)
    # The mirror of `edit` falling through to git's editor chain: a `diff.tool`
    # the user set is a tool they already chose for reading a diff, and anchor's
    # own preference for an annotating viewer is not a reason to override them.
    [[ -n "$b" ]] || b=$(anchor_difftool_configured)
  fi
  if [[ -z "$b" ]]; then src=default; b=revdiff; fi
  resolved_backend="$b"
  resolved_backend_source="$src"
}

# Can this mode open here at all? `edit` needs an editor *and* somewhere to draw
# it; `diff` needs its viewer on PATH.
mode_available() {
  case "$1" in
    edit) anchor_editor_available ;;
    # A viewer answers on PATH; a difftool answers to git, which can launch a
    # name that is no binary of its own.
    *)    command -v "$resolved_backend" >/dev/null 2>&1 \
            || anchor_difftool_known "$resolved_backend" ;;
  esac
}

# The mode to run, or the one that can open standing in for it. A mode the
# *subject* picked is anchor's own read, so an `edit` with nowhere to open gives
# way to a viewer rather than dead-ending a flow in a host problem the user was
# never warned about. A mode a caller *asked* for with --mode is kept whether or
# not it can open, so its own report names the missing piece: that flag is how a
# probe's answer reaches the launch, and quietly running a different shape than
# the one just reported is the disagreement the probe exists to prevent.
usable_mode() {
  local preferred="$1"
  if [[ "$preferred" == "edit" && "$resolved_mode_source" == "subject" ]] \
     && ! anchor_editor_available && command -v revdiff >/dev/null 2>&1; then
    printf 'diff'; return
  fi
  printf '%s' "$preferred"
}

# The viewer to run, or an installed one standing in for it. This is the
# within-mode question and it is asked of `diff` alone: a named viewer that is
# not installed coalesces onto the default rather than dead-ending, and nothing
# installed leaves the name as resolved so the probe's REVIEW_AVAILABLE=0 still
# reports what was preferred.
usable_backend() {
  local preferred="$1"
  [[ "$resolved_mode" == "diff" ]] || { printf '%s' "$preferred"; return; }
  if command -v "$preferred" >/dev/null 2>&1 || anchor_difftool_known "$preferred"; then
    printf '%s' "$preferred"; return
  fi
  if command -v revdiff >/dev/null 2>&1; then printf '%s' revdiff; return; fi
  printf '%s' "$preferred"
}

# Both axes, resolved together and in order — the backend question is asked of a
# settled mode, and a mode that gave way re-asks it.
resolve_review() {
  resolve_mode
  resolve_backend
  local m
  m=$(usable_mode "$resolved_mode")
  if [[ "$m" != "$resolved_mode" ]]; then
    preferred_mode="$resolved_mode"
    resolved_mode="$m"
    resolved_backend=""; resolved_backend_source=""
    resolve_backend
  fi
  preferred_backend="$resolved_backend"
  resolved_backend=$(usable_backend "$resolved_backend")
}
preferred_mode=""
preferred_backend=""

if [[ "$probe_only" == "1" ]]; then
  report_superseded_key
  resolve_review
  edit_available=0
  anchor_editor_available && edit_available=1
  echo "REVIEW_MODE=$resolved_mode"
  echo "REVIEW_MODE_SOURCE=$resolved_mode_source"
  # What the preference named, reported only when the run would use something
  # else — a mode the subject picked with nowhere to open, or a key that named an
  # absent viewer. Either way the caller has a name to say out loud, so what
  # opens isn't discovered as a surprise window.
  [[ -z "$preferred_mode" ]] || echo "REVIEW_MODE_CONFIGURED=$preferred_mode"
  echo "REVIEW_BACKEND=$resolved_backend"
  echo "REVIEW_BACKEND_SOURCE=$resolved_backend_source"
  [[ "$resolved_backend" == "$preferred_backend" ]] || echo "REVIEW_BACKEND_CONFIGURED=$preferred_backend"
  if mode_available "$resolved_mode"; then
    echo "REVIEW_AVAILABLE=1"
  else
    # A mode that is selected but cannot open is as unavailable as an absent
    # viewer; saying otherwise sends the caller to launch a review that reports a
    # host problem instead of showing anything.
    echo "REVIEW_AVAILABLE=0"
  fi
  echo "REVIEW_EDIT_AVAILABLE=$edit_available"
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

review_subject="range"
files_left=""
files_right=""
diff_range=""
header_mode=""
review_title=""
review_details_json="[]"
message_file=""

if [[ "${1:-}" == "--files" ]]; then
  review_subject="files"
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

# --- Select the mode's adapter and delegate ----------------------------------

report_superseded_key
resolve_review
review_mode="$resolved_mode"
review_backend="$resolved_backend"

# One adapter per mode. Within `diff`, the tool's own half lives in
# review/backends/<tool>.sh, which that adapter sources — so a second viewer is a
# file beside revdiff's rather than a branch here.
adapter="$(dirname "${BASH_SOURCE[0]}")/review/${review_mode}.sh"
if [[ ! -r "$adapter" ]]; then
  echo "review-diff.sh: unknown review mode '$review_mode' (no adapter at $adapter)." >&2
  exit 64
fi
# A machine with no viewer installed keeps the resolved adapter, whose report
# names the tool that is missing. There is nothing below it to degrade into —
# git's difftool is not a backend (DIFF-18) because a changeset shown without a
# verdict invites "you saw it, approve?", which is the rubber stamp the contract
# exists to prevent. The skill's fallback ladder (guides/review-fallback.md) is
# the rung below.

# An empty range has nothing to show, and a viewer opened on nothing is quit the
# same way an approved review is — so launching one manufactures an `approved`
# for a changeset nobody saw. Report `no-verdict` naming the repo the range
# resolved against, which is also what surfaces a review pointed at the wrong
# checkout (DIFF-21).
if [[ "$review_subject" == "range" ]] && git diff --quiet "$diff_range" -- 2>/dev/null; then
  echo "review-diff.sh: $diff_range is empty in $(git rev-parse --show-toplevel) (target resolved via ${RESOLVED_VIA:-cwd}) — nothing to review" >&2
  jq -cn --arg m "$review_mode" --arg b "$review_backend" --arg r "$diff_range" '{
    mode:$m, backend:$b, verdict:"no-verdict",
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
export review_subject review_mode review_backend
export diff_range files_left files_right review_title review_details_json
export message_file review_skill

# shellcheck source=/dev/null
source "$adapter"
emit_review
