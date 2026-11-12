#!/usr/bin/env bash
# Dispatcher for anchor's visual diff review. Resolves the diff range and the
# header from the requested mode, selects the review tool, and delegates the
# launch-and-normalize to that tool's adapter, which prints the result on
# stdout so the caller acts on a single command's output:
#   REVIEW_VERDICT=<approved|changes-requested|rejected|incomplete|no-verdict>
#   REVIEW_OUTPUT=<normalized json>   (the DIFF contract; see SPEC.md "DIFF")
# and, for --local, a line before the tool opens:
#   REVIEW_INDEX=<id>   the reviewed paths' index entries, for commit.sh
#                       --reviewed-index (scripts/lib/stage-paths.sh)
#
# The mode follows the subject: `edit` where the review is one file with no prior
# version, `diff` everywhere else. Adapters live in scripts/review/, one per mode,
# and each defines emit_review; a diff tool's own half lives under
# scripts/review/tools/. Range/header resolution is mode-agnostic and stays
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
#     1 unpushed commit         -> <pushed copy>...HEAD (the upstream, when it carries the branch's name)
#     2+ unpushed commits       -> HEAD~1...HEAD (prior commits already reviewed)
#     no upstream tracking      -> <parent of the oldest commit no origin ref holds>...HEAD
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
#   bash review-diff.sh --files <left> <right> [--name <ref>] [--title <t>] [--detail label=value]...
# --name is the reviewed object's own reference (`<repo>#<number>`, `<repo>!<iid>`,
# `<repo>@<version>`), which names the file in the viewer and the editor in place
# of the right side's temp name, so the review says which object it edits.

set -euo pipefail

# Context flags, accepted anywhere in the argv:
#   --repo <path>  retargets the git range / review onto a checkout other than
#     the cwd repo (see scripts/lib/resolve-context.sh). The --files mode takes
#     absolute paths, so this is only meaningful for the git-range modes.
#   --path <p>  a path for --local to stage, repeatable, resolved against the repo
#     root. Only these are staged: a whole-tree add would pull a session sharing
#     the checkout into this review (see scripts/lib/stage-paths.sh).
#   --staged-path <p>  a partly staged path for --local, repeatable: never staged,
#     and the review shows the index against HEAD rather than the working tree,
#     which still holds the hunks the commit leaves out.
# A review is resolved on two axes, and they are not the same question:
#
#   mode     the shape the review takes — `edit` or `diff`. The subject decides
#            it (subject_default_mode); there is no key, because the shape that
#            fits is a property of what is being reviewed rather than a taste.
#   tool     the tool that runs that mode. `anchor.edit.tool` names the
#            editor (else git's chain). Every `diff` review runs revdiff
#            (CONFIG-15a): `anchor.diff.tool` and git's `diff.tool` are read
#            only to say, once, that a value naming another viewer is ignored.
#
# A third thing decides where the review lands on screen — the host — and this
# script does not resolve it, because it is neither a property of the review nor
# a preference: the session settles it. That lives in scripts/lib/review-host.sh,
# is asked of one ranked set for both modes, and is the other half of the
# availability question below.
#
#   --skill <name>  tells an adapter which artifact is under review. It does not
#     pick the mode — the subject does, always.
#   --mode <edit|diff>  run this mode rather than the one the subject picks —
#     what a caller passes back after probing, so the review opens in the shape
#     the probe said was reachable.
#   --tool <name>  run this tool within the mode, ignoring the config key.
#   --notes <notes.json>  the agent's notes on its own changes in a --local
#     review (UX-12), in the shape scripts/lib/change-notes.sh documents. Each is
#     placed on the line it is about before anything opens; a note with nowhere
#     to show prints NOTES_ERROR=<message>, and the review exits 65 without
#     opening. Preloaded where the tool can show notes, and left out where it
#     can't, so the review opens either way (the probe's REVIEW_PRELOADS says
#     which). A note returned as placed, or deleted, was read; only an edited or
#     a new one is the reviewer answering.
#   --annotations <file>  preload these notes into the review, in revdiff's
#     own markdown (`## <path>:<line> (+|-| )` then the body). The reviewer
#     reads, edits, and deletes them in place, and the set they leave comes back
#     as the comments, plus REVIEW_RETURNED=<path> holding that set as JSON. A
#     tool that can't preload notes refuses the review rather than dropping them.
#   --untracked  show untracked files in the tree too (a working-tree review
#     only), so a file the review writes for the reviewer to edit is in front of
#     them. Refused the same way by a tool that can't show one.
#   --reply <dir>  re-open a --local review as a reply to the last one: the
#     state dir a `changes-requested` review printed as REVIEW_STATE, seeded by
#     review-reply.sh. The diff runs from the changeset as that review closed to
#     the tree now, so it shows what changed in answer; the replies are preloaded
#     as notes and head the context file, and a note returned as it was seeded is
#     the reply rather than feedback (DIFF-37). The context file stacks the size
#     of each pass, newest first, down to the change the first review saw
#     (DIFF-38), written to `sizes.tsv` in that dir for the tool to draw.
#   A `--local` review that comes back `changes-requested` prints
#     REVIEW_STATE=<dir> for that --reply: the changeset as the review closed
#     (`reviewed`, a commit), the comments it returned (`comments.json`), and
#     on a reply, the changeset as each review before it closed (`earlier`,
#     oldest first).
#   --probe  report how a review would resolve, and exit without launching
#     anything — what a skill asks before deciding whether a visual review is
#     available at all. Pass it the same mode flag and paths as the launch: the
#     default reads the subject, so a bare probe on a `--files` review answers
#     for a review nobody is about to open. It considers only tools that can
#     actually open:
#       REVIEW_MODE=edit|diff              what to pass to --mode
#       REVIEW_MODE_SOURCE=override|config|subject
#       REVIEW_MODE_CONFIGURED=<mode>      only when the run uses another
#       REVIEW_TOOL=<command>           the tool that will open — an editor
#         in `edit` mode, revdiff in `diff`.
#       REVIEW_TOOL_SOURCE=override|config|default|required
#         `required` is `diff` mode's revdiff, which no key chooses.
#       REVIEW_AVAILABLE=0|1               0 = this mode cannot open here.
#         Both halves are asked: the program, and the host that would draw it
#         (scripts/lib/review-host.sh) — an installed viewer with no terminal to
#         render in is as unavailable as an editor with nowhere to go.
#         The SOURCE pair says whether what is about to open is something the
#         user chose, so a launch that fell through to git's own key can name the
#         anchor key that would make it a choice (UX-07).
#       REVIEW_UNUSABLE=<reason>           with 0 in `diff`: revdiff is missing
#         or too old, and the reason names the install or the upgrade. The
#         review stops there; the fallback ladder is for a host that can't
#         open a pane.
#       REVIEW_EDIT_AVAILABLE=0|1          1 = --mode edit would reach an
#         editor. Reported on its own axis because it answers a different
#         question: not "which viewer shows the changeset" but "can the user be
#         handed the drafted artifact to edit" — the rung a skill offers when
#         the pane couldn't open or the review died
#         (see guides/review-fallback.md).
#       REVIEW_HOST=tmux|gui|iterm2|agterm|launcher   where the review will be
#         drawn (scripts/review/hosts/); empty when nowhere can. The manifest
#         names it, since a split of the session's pane doesn't take the eye the
#         way a popup or an overlay over it does.
# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/review-editor.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-editor.sh"
# shellcheck source=lib/review-host.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/review-host.sh"
# shellcheck source=lib/stage-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/stage-paths.sh"
# shellcheck source=lib/size-stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/size-stack.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"
# shellcheck source=lib/item-review.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/item-review.sh"
# shellcheck source=lib/change-notes.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/change-notes.sh"
CTX_REPO=""
review_skill=""
mode_override=""
tool_override=""
review_annotations=""
review_notes=""
review_seeded=""
review_reply=""
review_untracked=0
local_base=HEAD
probe_only=0
stage_paths=()
staged_paths=()
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
    --tool)  tool_override="${2:?--tool needs a name}"; shift 2 ;;
    --path)     stage_paths+=("${2:?--path needs a path}"); shift 2 ;;
    --staged-path) staged_paths+=("${2:?--staged-path needs a path}"); shift 2 ;;
    --annotations) review_annotations="${2:?--annotations needs a file}"; shift 2 ;;
    --notes)    review_notes="${2:?--notes needs a notes file}"; shift 2 ;;
    --reply)    review_reply="${2:?--reply needs the state dir review-reply.sh seeded}"; shift 2 ;;
    --untracked) review_untracked=1; shift ;;
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
  echo "review-diff.sh: anchor.reviewBackend ('$legacy') no longer does anything. The review's shape now follows what it is reviewing, anchor.edit.tool names the editor, and diff reviews open in revdiff." >&2
}

# The key that would have chosen the viewer before 2.0, read only to say that it
# is ignored: anchor.diff.tool where set, else git's own diff.tool. A key set to
# revdiff already says what runs, so it prints nothing.
report_ignored_viewer_key() {
  [[ "$resolved_mode" == diff && -z "$tool_override" ]] || return 0
  local key=anchor.diff.tool value
  value=$(git config --get "$key" 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    key=diff.tool
    value=$(git config --get "$key" 2>/dev/null || true)
  fi
  [[ -n "$value" && "$value" != revdiff ]] || return 0
  echo "review-diff.sh: $key names '$value', and anchor 2.0 reviews every diff in revdiff, so $key is ignored." >&2
}

# Resolution answers are set rather than printed: a `$(...)` call would run the
# function in a subshell and drop the source along with it. The source is where
# the name came from, and substitution reads it — a tool the user typed is
# honored even when it cannot open, where one anchor picked is not.
resolved_mode=""
resolved_mode_source=""
resolved_tool=""
resolved_tool_source=""

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

# Which tool runs the resolved mode. `edit` takes anchor.edit.tool, then git's
# own editor chain and anchor's rungs past it (scripts/lib/review-editor.sh).
# `diff` runs revdiff and reads no key (CONFIG-15a): its context file, preloaded
# notes, and Review box are what a 2.0 review is, and a viewer without them has
# no verdict to give.
resolve_tool() {
  if [[ -n "$tool_override" ]]; then
    resolved_tool="$tool_override"; resolved_tool_source=override; return
  fi
  if [[ "$resolved_mode" == "edit" ]]; then
    resolved_tool=$(anchor_editor_resolve)
    resolved_tool_source=$(anchor_editor_source)
    return
  fi
  resolved_tool=revdiff
  resolved_tool_source=required
}

# Can this mode open here at all? Both need a program *and* somewhere to draw
# it, and both are asked the same way — a viewer that is installed with no
# terminal to render in opens no more than an editor with nowhere to go.
mode_available() {
  case "$1" in
    edit) anchor_editor_available ;;
    *)    command -v "$resolved_tool" >/dev/null 2>&1 \
            && [[ -z "$(tool_unusable)" ]] \
            && anchor_host_available diff ;;
  esac
}

# The mode to run, or the one that can open standing in for it. A mode the
# *subject* picked is anchor's own read, so an `edit` with nowhere to open gives
# way to a viewer rather than dead-ending a flow in a host problem the user was
# never warned about. A mode a caller *asked* for with --mode is kept whether or
# not it can open, so its own report names the missing piece: that flag is how a
# probe's answer reaches the launch, and quietly running a different shape than
# the one just reported is the disagreement the probe exists to prevent.
#
# Giving way takes a `diff` review that can actually open: revdiff installed and
# new enough, and a host to draw it in. Where it can't, the subject's `edit` is
# kept and its own report names the editor problem instead of trading it for a
# viewer problem.
#
# The `diff` half is resolved and asked here rather than read off the settled
# state, which still holds `edit`'s editor at this point — the two answers would
# otherwise be crossed, and the mode would give way on whether an *editor* is
# installed.
diff_mode_openable() {
  local keep_mode="$resolved_mode" keep_tool="$resolved_tool" keep_src="$resolved_tool_source"
  local openable=1
  resolved_mode="diff"; resolved_tool=""; resolved_tool_source=""
  resolve_tool
  mode_available diff || openable=0
  resolved_mode="$keep_mode"; resolved_tool="$keep_tool"; resolved_tool_source="$keep_src"
  [[ "$openable" -eq 1 ]]
}

usable_mode() {
  local preferred="$1"
  if [[ "$preferred" == "edit" && "$resolved_mode_source" == "subject" ]] \
     && ! anchor_editor_available \
     && diff_mode_openable; then
    printf 'diff'; return
  fi
  printf '%s' "$preferred"
}

# Both axes, resolved together and in order — the tool question is asked of a
# settled mode, and a mode that gave way re-asks it. There is no within-mode
# substitution: a revdiff that is missing stays named, so the report says what
# to install instead of opening a different tool.
resolve_review() {
  resolve_mode
  resolve_tool
  local m
  m=$(usable_mode "$resolved_mode")
  if [[ "$m" != "$resolved_mode" ]]; then
    preferred_mode="$resolved_mode"
    resolved_mode="$m"
    resolved_tool=""; resolved_tool_source=""
    resolve_tool
  fi
}
preferred_mode=""

# Whether the resolved tool shows notes preloaded into it: a diff tool whose
# adapter says so. Asked of the adapter in a subshell, so the probe answers from
# the same capabilities the launch acts on.
tool_preloads() {
  [[ "$resolved_mode" == diff && -n "$resolved_tool" ]] || { echo 0; return; }
  (
    # shellcheck source=review/modes/diff.sh
    source "$(dirname "${BASH_SOURCE[0]}")/review/modes/diff.sh"
    f=$(diff_tool_file "$resolved_tool")
    [[ -n "$f" ]] || { echo 0; exit 0; }
    # shellcheck source=/dev/null
    source "$f"
    if [[ "$(jq -r '.preloadsAnnotations // false' <<<"$diff_tool_caps")" == true ]]; then echo 1; else echo 0; fi
  )
}

# Why the resolved diff tool can't run the review, asked of its adapter as the
# launch asks it: not installed, or too old (DIFF-48). Empty when it can.
tool_unusable() {
  (
    # shellcheck source=review/modes/diff.sh
    source "$(dirname "${BASH_SOURCE[0]}")/review/modes/diff.sh"
    f=$(diff_tool_file "$resolved_tool")
    [[ -n "$f" ]] || exit 0
    # shellcheck source=/dev/null
    source "$f"
    if ! bin=$(command -v "$resolved_tool" 2>/dev/null); then
      printf '%s is not installed (%s)' "$resolved_tool" "$diff_tool_install_hint"
      exit 0
    fi
    ! declare -F diff_tool_unusable >/dev/null || diff_tool_unusable "$bin" || true
  )
}

# What a review's announcements name as under review (DIFF-47): the CR a review
# names, else a drafted document's title, else the repository the range is read
# from. Read off the arguments the probe was given, the launch's own.
review_span_target() {
  local title="" cr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)  title="${2:-}"; shift 2 ;;
      --detail) [[ "${2:-}" != CR=* ]] || cr="${2#CR=}"; shift 2 ;;
      *)        shift ;;
    esac
  done
  if [[ -n "$cr" ]]; then
    printf '%s' "$cr"
  elif [[ "$subject_flag" == "--files" && -n "$title" ]]; then
    printf '%s' "$title"
  else
    git rev-parse --show-toplevel 2>/dev/null || true
  fi
}

if [[ "$probe_only" == "1" ]]; then
  report_superseded_key
  resolve_review
  report_ignored_viewer_key
  edit_available=0
  anchor_editor_available && edit_available=1
  # The two answers first, then where each came from, then what the preference
  # named where the run would use something else. Grouping by axis put a source
  # between the mode and the tool, which is the pair a reader is after.
  echo "REVIEW_MODE=$resolved_mode"
  echo "REVIEW_TOOL=$resolved_tool"
  echo "REVIEW_MODE_SOURCE=$resolved_mode_source"
  echo "REVIEW_TOOL_SOURCE=$resolved_tool_source"
  # Reported only when the run would use something else — a mode the subject
  # picked with nowhere to open. The caller has a name to say out loud, so what
  # opens isn't discovered as a surprise window.
  [[ -z "$preferred_mode" ]] || echo "REVIEW_MODE_CONFIGURED=$preferred_mode"
  if mode_available "$resolved_mode"; then
    echo "REVIEW_AVAILABLE=1"
    # DIFF-47: the review is about to open, said from this foreground call
    # because the launch runs in the background, where nothing it prints is seen
    # until it is over. A subscriber marks the session before the next tool call
    # opens the review.
    bash "$(dirname "${BASH_SOURCE[0]}")/announce.sh" attention.requested \
      "target=$(review_span_target "$@")" "skill=${review_skill}" || true
  else
    # A mode that is selected but cannot open is as unavailable as an absent
    # viewer; saying otherwise sends the caller to launch a review that reports a
    # host problem instead of showing anything.
    echo "REVIEW_AVAILABLE=0"
    if [[ "$resolved_mode" == diff ]]; then
      unusable=$(tool_unusable)
      [[ -z "$unusable" ]] || echo "REVIEW_UNUSABLE=$unusable"
    fi
  fi
  echo "REVIEW_EDIT_AVAILABLE=$edit_available"
  echo "REVIEW_PRELOADS=$(tool_preloads)"
  if [[ "$resolved_mode" == edit ]]; then
    echo "REVIEW_HOST=$(anchor_editor_host "$(anchor_editor_resolve)")"
  else
    echo "REVIEW_HOST=$(anchor_review_host diff)"
  fi
  exit 0
fi

# DIFF-47: the review is over on every way out of a launch, an early refusal or a
# killed dispatcher included, so a subscriber's mark never outlives it. A fatal
# signal skips the EXIT trap unless it is trapped too.
# An EXIT trap's own status replaces the script's, so this one can't fail.
announce_review_released() {
  bash "$(dirname "${BASH_SOURCE[0]}")/announce.sh" attention.released || true
}
trap announce_review_released EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Resolve "the whole branch vs the default branch" range. Tries the symbolic
# origin/HEAD first, then the conventional origin/main and origin/master.
# Pure git plumbing — kept in a script so the brace tokens don't trip Claude
# Code's bash safety analyzer from skill prose.
determine_default_branch_range() {
  local default
  default=$(anchor_default_branch) || return 1
  echo "origin/${default}...HEAD"
}

# Determine the diff range for a commit review from the unpushed commit count:
# every unpushed commit, since the push that follows sends all of them.
determine_commit_range() {
  local count="" base pushed_ref
  if pushed_ref=$(anchor_pushed_ref); then
    count=$(git rev-list --count "${pushed_ref}..HEAD" 2>/dev/null || true)
  fi
  if [[ -z "$count" ]]; then
    base=$(anchor_unpushed_base) || return 1
    echo "${base}...HEAD"
  elif [[ "$count" -ge 1 ]]; then
    echo "${pushed_ref}...HEAD"
  else
    echo "HEAD~1...HEAD"
  fi
}

# --- Resolve the review request (mode-agnostic vars the adapter reads) --------

review_subject="range"
files_left=""
files_right=""
files_name=""
diff_range=""
diff_staged=0
diff_paths=""
review_index=""
header_mode=""
reviews_unpushed=0
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
      --name)
        files_name="${2:?--name needs a value}"; shift 2
        if [[ "$files_name" == */* ]]; then
          echo "review-diff.sh: --name is a file name, and '$files_name' holds a '/'; pass the repo's last path segment" >&2
          exit 64
        fi
        ;;
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
      echo "review-diff.sh: could not determine a diff range (no upstream tracking branch, and origin has no refs here to measure the unpushed commits against)" >&2
      exit 65
    }
    header_mode="commit"
    reviews_unpushed=1
    expect_consumed "${@:2}"
  elif [[ "${1:-}" == "--local" ]]; then
    local_base=$(anchor_local_base)
    diff_range="$local_base"
    header_mode="local"
    if [[ -n "$review_reply" ]]; then
      [[ -s "$review_reply/reviewed" && -f "$review_reply/notes.json" && -f "$review_reply/reply.md" ]] || {
        echo "review-diff.sh: --reply needs a state dir review-reply.sh has seeded: $review_reply" >&2; exit 66; }
      [[ -z "$review_annotations$review_notes" ]] || { echo "review-diff.sh: --reply brings its own notes; drop --annotations and --notes" >&2; exit 64; }
      [[ ${#staged_paths[@]} -eq 0 ]] || {
        echo "review-diff.sh: --reply diffs the working tree against the last review, and a --staged-path review shows the index" >&2; exit 64; }
      diff_range=$(cat "$review_reply/reviewed")
      review_annotations="$review_reply/notes.md"
    fi
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
    # A partly staged path leaves hunks in the working tree that the commit does
    # not carry, so the review shows the index instead.
    anchor_require_staged "review-diff.sh" "${staged_paths[@]+"${staged_paths[@]}"}"
    [[ ${#staged_paths[@]} -eq 0 ]] || diff_staged=1
    # The review covers the paths the commit will carry and nothing else, so a
    # peer's edits elsewhere in the tree stay out of it (COMMIT-14), and the
    # source side of a named rename comes along with it, as it does in the commit.
    review_paths=("${stage_paths[@]+"${stage_paths[@]}"}" "${staged_paths[@]+"${staged_paths[@]}"}")
    while IFS= read -r src; do review_paths+=("$src"); done \
      < <(anchor_rename_sources "${review_paths[@]+"${review_paths[@]}"}")
    review_index=$(anchor_index_digest "${review_paths[@]+"${review_paths[@]}"}")
    for named_path in "${review_paths[@]+"${review_paths[@]}"}"; do
      diff_paths+="$named_path"$'\n'
    done
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
  branch=$(git symbolic-ref --quiet --short HEAD || git rev-parse --short HEAD)

  review_specs=()
  while IFS= read -r spec; do review_specs+=("$spec"); done < <(anchor_diff_specs)

  if [[ "$header_mode" == "local" ]]; then
    stat=$(git diff --cached --stat "$local_base" -- "${review_specs[@]+"${review_specs[@]}"}" | tail -1 | sed 's/^[[:space:]]*//')
    if [[ -n "$review_reply" ]]; then
      # Newest first: what changed since the last review closed, what changed
      # after each review before it, and the change as the first review saw it.
      passes=()
      if [[ -f "$review_reply/earlier" ]]; then
        while IFS= read -r snap; do passes+=("$snap"); done < "$review_reply/earlier"
      fi
      passes+=("$(cat "$review_reply/reviewed")")
      {
        git diff --numstat --no-renames "${passes[${#passes[@]} - 1]}" -- "${review_specs[@]+"${review_specs[@]}"}" \
          | anchor_size_row "this round"
        for (( i = ${#passes[@]} - 1; i >= 1; i-- )); do
          git diff --numstat --no-renames "${passes[i - 1]}" "${passes[i]}" -- "${review_specs[@]+"${review_specs[@]}"}" \
            | anchor_size_row "after review $i"
        done
        git diff --numstat --no-renames "$local_base" "${passes[0]}" -- "${review_specs[@]+"${review_specs[@]}"}" \
          | anchor_size_row "original change"
      } > "$review_reply/sizes.tsv"
    fi
    base=""
    [[ "$local_base" != HEAD ]] || base=$(git log -1 --format='%h %s' HEAD)
    if [[ -n "$message_file" ]]; then
      # Seed the drafted message: subject is the review's headline, the body row
      # is the message prose the tool renders, so message + diff are reviewed
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
    stat=$(git diff --shortstat "$diff_range" 2>/dev/null | sed 's/^[[:space:]]*//')
    review_details_json=$(jq -n \
      --arg repo "$repo" --arg br "$branch" --arg base "$base_ref" \
      --arg r "$diff_range" --arg n "$count" --arg s "$stat" \
      '[{label:"repo",value:$repo},{label:"branch",value:$br},
        {label:"base",value:$base},{label:"range",value:$r},{label:"commits",value:$n}]
       + (if $s == "" then [] else [{label:"summary",value:$s}] end)')
  else
    subject=$(git log -1 --format=%s HEAD)
    body=$(git log -1 --format=%b HEAD)
    hash=$(git log -1 --format=%h HEAD)
    author=$(git log -1 --format='%an <%ae>' HEAD)
    review_title="$subject"
    stat=$(git diff --shortstat "$diff_range" 2>/dev/null | sed 's/^[[:space:]]*//')
    review_details_json=$(jq -n \
      --arg repo "$repo" --arg br "$branch" --arg c "$hash" \
      --arg a "$author" --arg b "$body" --arg r "$diff_range" --arg s "$stat" \
      '[{label:"repo",value:$repo},{label:"branch",value:$br},
        {label:"commit",value:$c},{label:"author",value:$a},{label:"range",value:$r}]
       + (if $s == "" then [] else [{label:"summary",value:$s}] end)
       + (if $b == "" then [] else [{label:"body",value:$b}] end)')
  fi

  # An override replaces the computed value rather than merging with it: the
  # computed header describes a different subject entirely, so keeping half of
  # it would attribute the range to the wrong commit.
  [[ -n "$override_title" ]] && review_title="$override_title"
  [[ -n "$override_details_json" ]] && review_details_json="$override_details_json"
fi

if [[ -n "$review_annotations" && ! -r "$review_annotations" ]]; then
  echo "review-diff.sh: annotations file not readable: $review_annotations" >&2
  exit 66
fi
review_notes_md=""
if [[ -n "$review_notes" ]]; then
  [[ -z "$review_annotations" ]] || { echo "review-diff.sh: --notes and --annotations are two sets of notes; pass one" >&2; exit 64; }
  [[ "$header_mode" == local ]] || { echo "review-diff.sh: --notes annotates a --local review" >&2; exit 64; }
  [[ -r "$review_notes" ]] || { echo "review-diff.sh: --notes file not readable: $review_notes" >&2; exit 66; }
  placed=$(anchor_change_notes_place "$review_notes" "${stage_paths[@]+"${stage_paths[@]}"}") || { printf '%s\n' "$placed"; exit 65; }
  review_notes_md="$placed"
fi
if [[ "$review_untracked" -eq 1 && ( "$review_subject" != "range" || "$diff_range" == *..* ) ]]; then
  echo "review-diff.sh: --untracked shows files beside a working-tree diff; $([[ "$review_subject" == range ]] && echo "$diff_range compares two commits" || echo "a --files review has no tree")" >&2
  exit 64
fi

if [[ -n "$review_reply" && "$review_annotations" != "$review_reply/notes.md" ]]; then
  echo "review-diff.sh: --reply answers a --local review" >&2
  exit 64
fi

if [[ ${#staged_paths[@]} -gt 0 && "$diff_staged" -ne 1 ]]; then
  echo "review-diff.sh: --staged-path applies to --local only" >&2
  exit 64
fi

# A review opens partway through a flow and can wait while the user works
# elsewhere, so the header leads with the flow that opened it and what approving
# hands it, for a reviewer coming back to it cold.
review_next_step() {
  case "$review_skill" in
    commit)
      if [[ "$header_mode" == "local" ]]; then echo "commit this change and push it"
      elif [[ "$reviews_unpushed" -eq 1 ]]; then echo "push these commits"; fi ;;
    prepare-review) echo "open or update the CR with this description" ;;
    issue)          echo "file or update the issue with this body" ;;
    release)        echo "use these notes for the release" ;;
    resolve-feedback)
      [[ "$header_mode" != "local" ]] || echo "commit this fix and push it" ;;
    review)         echo "your notes decide what each item becomes; nothing commits or posts until you approve it" ;;
  esac
}
if [[ -n "$review_skill" ]]; then
  review_details_json=$(jq -c --arg s "/anchor:$review_skill" --arg n "$(review_next_step)" \
    '[{label:"opened by",value:$s}] + (if $n == "" then [] else [{label:"next",value:$n}] end) + .' \
    <<<"$review_details_json")
fi

# --- Select the mode's adapter and delegate ----------------------------------

report_superseded_key
resolve_review
report_ignored_viewer_key
review_mode="$resolved_mode"
review_tool="$resolved_tool"
if [[ -n "$review_notes_md" && "$(tool_preloads)" == 1 ]]; then
  review_annotations="$review_notes_md"
  review_seeded="${review_notes_md%.md}.json"
fi
if [[ "$review_mode" != diff ]] && [[ -n "$review_annotations" || "$review_untracked" -eq 1 ]]; then
  echo "review-diff.sh: --annotations and --untracked belong to a diff review, and this one resolved to $review_mode mode" >&2
  exit 64
fi
# A review of items (a batch, a round) preloads notes of its own and writes its
# own context file; a reply and the agent's notes on its changes preload notes
# but ride with the tool's context file.
review_items=""
[[ -z "$review_annotations" || -n "$review_seeded" || -n "$review_reply" ]] || review_items=1

# One adapter per mode. Within `diff`, the tool's own half lives in
# review/tools/<tool>.sh, which that adapter sources.
adapter="$(dirname "${BASH_SOURCE[0]}")/review/modes/${review_mode}.sh"
if [[ ! -r "$adapter" ]]; then
  echo "review-diff.sh: unknown review mode '$review_mode' (no adapter at $adapter)." >&2
  exit 64
fi
# A machine without revdiff keeps the resolved adapter, whose report names the
# install. There is nothing below it to degrade into: a changeset shown without
# a verdict invites "you saw it, approve?", which is the rubber stamp the
# contract exists to prevent.

# An empty range has nothing to show, and a viewer opened on nothing is quit the
# same way an approved review is — so launching one manufactures an `approved`
# for a changeset nobody saw. Report `no-verdict` naming the repo the range
# resolved against, which is also what surfaces a review pointed at the wrong
# checkout (DIFF-21). A reply opens on an empty range: its notes answer
# questions that changed nothing, and the changeset itself was graded already.
# Under --untracked a new file is part of what is shown, so a batch of nothing
# but new items is not empty; the context file is the review's own, not content.
range_empty() {
  [[ -z "$review_reply" ]] || return 1
  if [[ "$review_untracked" -eq 1 ]] \
     && git ls-files --others --exclude-standard -- "${review_specs[@]+"${review_specs[@]}"}" \
          | grep -qvxF '(context).md'; then
    return 1
  fi
  if [[ "$diff_staged" -eq 1 ]]; then git diff --cached --quiet "$diff_range" -- "${review_specs[@]+"${review_specs[@]}"}"
  else git diff --quiet "$diff_range" -- "${review_specs[@]+"${review_specs[@]}"}"; fi
}
if [[ "$review_subject" == "range" ]] && range_empty 2>/dev/null; then
  echo "review-diff.sh: $diff_range is empty in $(git rev-parse --show-toplevel) (target resolved via ${RESOLVED_VIA:-cwd}) — nothing to review" >&2
  jq -cn --arg m "$review_mode" --arg b "$review_tool" --arg r "$diff_range" '{
    mode:$m, tool:$b, verdict:"no-verdict",
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
export review_subject review_mode review_tool
export diff_range diff_staged diff_paths files_left files_right files_name review_title review_details_json
export message_file review_skill review_annotations review_seeded review_reply review_items review_untracked

# Taken before the tool opens, so it names what the reviewer was shown.
[[ -z "$review_index" ]] || echo "REVIEW_INDEX=$review_index"

# Called by the adapter once a review returns `changes-requested`. The tree is
# taken as the review closed, so an edit the reviewer made in the tool is part
# of what they saw, and the next review (--reply) shows only what answered them.
review_state_save() {
  [[ "$header_mode" == local && "$diff_staged" -eq 0 ]] || return 0
  local dir
  dir=$(anchor_tmpdir anchor-review-state)
  anchor_review_snapshot "${review_paths[@]+"${review_paths[@]}"}" > "$dir/reviewed"
  printf '%s\n' "$1" > "$dir/comments.json"
  if [[ -n "$review_reply" ]]; then
    { [[ ! -f "$review_reply/earlier" ]] || cat "$review_reply/earlier"; cat "$review_reply/reviewed"; } > "$dir/earlier"
  fi
  echo "REVIEW_STATE=$dir"
}

# shellcheck source=/dev/null
source "$adapter"
emit_review
