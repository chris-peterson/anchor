#!/usr/bin/env bash
# editor backend adapter for review-diff.sh (see SPEC.md "DIFF").
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_mode          "range" | "files"
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#   message_file         the drafted commit message (range mode, --message-file)
#   review_skill         the invoking skill, when the caller passed --skill
#
# The diff-viewer backends ask the reviewer to *comment* on a draft and anchor
# rewrites from the comments. This one is the other shape of that step: it opens
# the draft in the user's editor, and whatever they save IS the artifact. So the
# contract's comments array is always empty here, and the text comes back as
# editedFields.
#
# The buffer is git's own commit-message shape: the artifact on top, a scissors
# line, and the change under review below it. Everything below the scissors is
# discarded. Unlike git, lines starting with `#` are NOT stripped — three of the
# four artifacts anchor drafts are markdown, where `#` is a heading.
#
# Verdict mapping (DIFF-13):
#   saved, changed or not -> approved; a changed artifact rides back in
#                            editedFields and is adopted verbatim
#   emptied, or the editor exited non-zero (vim's `:cq`) -> no-verdict, which
#                            already halts the flow and is never read as approval
#
# An editor carries one artifact, so a review with no drafted artifact (a
# diff-only range review) is `no-verdict` with the cause on stderr rather than a
# silent pass — set a visual backend for those skills.
#
# Editor resolution and host selection live in the lib because the dispatcher's
# --print-backend probe needs the same answers without opening anything.
# shellcheck source=../lib/review-editor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/review-editor.sh"
# shellcheck source=../lib/split-run.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/split-run.sh"
# shellcheck source=../lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/tmpfile.sh"

editor_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":true,"editableDescription":true,"sideMarkers":false}'

# Cut point between the editable artifact and the read-only context below it.
# git's own marker, minus the leading `#`, since `#` lines are kept here.
editor_scissors='------------------------ >8 ------------------------'

editor_emit() {
  local verdict="$1" rc="$2" note="${3:-}" edited_json="${4:-[]}"
  local out
  out=$(jq -cn \
    --arg v "$verdict" --arg n "$note" \
    --argjson caps "$editor_caps" --argjson edited "$edited_json" \
    --arg rc "$rc" '
    {
      backend:"editor",
      verdict:$v,
      reviewCompleteness:null,
      reviewer:null,
      comments:[],
      editedFields:$edited,
      capabilities:$caps,
      raw:({exitCode:(($rc|tonumber?) // $rc)} + (if $n == "" then {} else {output:$n} end))
    }')
  echo "REVIEW_VERDICT=$verdict"
  echo "REVIEW_OUTPUT=$out"
}

# Shell-quote one argument for embedding in the command strings the overlay
# hosts take (they run `sh -c`, not an argv).
editor_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Read the exit code a popup left in its sentinel. `display-popup -E` has
# already blocked until the command exited, so this reads a file that is written
# by the time it is called; the loop covers the write landing a moment late.
editor_await() {
  local sentinel="$1"
  while [[ ! -s "$sentinel" ]]; do sleep 1; done
  cat "$sentinel"
}

# The extension the buffer takes. An editor picks its syntax mode from the name,
# not the content, so `.md` is what puts markdown preview a keystroke away for
# the three artifacts that are markdown; a commit message is git's plain-text
# shape and takes `.txt`.
editor_buffer_ext() {
  case "${1:-}" in
    commit-message) printf 'txt' ;;
    *)              printf 'md' ;;
  esac
}

# Open $2 in the resolved editor $1 and return the editor's exit status, in
# whichever host `anchor_editor_host` picked for this session.
editor_launch() {
  local ed="$1" file="$2" rc=0 cmd sentinel

  case "$(anchor_editor_host "$ed")" in
    launcher)
      "$ANCHOR_EDITOR_LAUNCHER" "$file" || rc=$?
      return "$rc"
      ;;
    tmux)
      # display-popup -E blocks until the command exits but reports its own status,
      # not the command's, so the status comes back through a sentinel.
      sentinel=$(mktemp "${TMPDIR:-/tmp}/anchor-editor-rc.XXXXXX")
      cmd="$ed $(editor_sq "$file"); printf %s \$? > $(editor_sq "$sentinel")"
      tmux display-popup -E -w 90% -h 90% "$cmd" >/dev/null 2>&1 || true
      rc=$(editor_await "$sentinel") || rc=124
      rm -f "$sentinel"
      return "$rc"
      ;;
    gui)
      # A blocking GUI editor needs no terminal at all, which makes running it
      # directly both correct and the only path that works in a Git Bash session.
      ( eval "$ed $(editor_sq "$file")" ) || rc=$?
      return "$rc"
      ;;
    tty)
      ( eval "$ed $(editor_sq "$file")" ) || rc=$?
      return "$rc"
      ;;
    iterm2)
      anchor_split_run "$ed $(editor_sq "$file")" || rc=$?
      return "$rc"
      ;;
  esac

  echo "review-diff.sh: no way to open '$ed' — a terminal editor needs a terminal, and this session has none. Run inside tmux, configure a blocking GUI editor (git config core.editor 'code --wait'), or point ANCHOR_EDITOR_LAUNCHER at a script that opens one." >&2
  return 125
}

# Consumes the review-request variables the dispatcher exports before sourcing
# this adapter; shellcheck can't follow that cross-file.
# shellcheck disable=SC2154
emit_review() {
  local artifact_file artifact_target

  # Which artifact is on the dial. The skill that asked for the review names it;
  # otherwise a seeded message is a commit message and the proposed side of a
  # two-path review is a description.
  case "${review_skill:-}" in
    commit)         artifact_target="commit-message" ;;
    prepare-review) artifact_target="description" ;;
    issue)          artifact_target="issue-body" ;;
    release)        artifact_target="release-notes" ;;
    *)              artifact_target="" ;;
  esac

  if [[ "$review_mode" == "files" ]]; then
    artifact_file="$files_right"
    [[ -n "$artifact_target" ]] || artifact_target="description"
  elif [[ -n "${message_file:-}" ]]; then
    artifact_file="$message_file"
    [[ -n "$artifact_target" ]] || artifact_target="commit-message"
  else
    echo "review-diff.sh: the editor backend edits a drafted artifact, and this review has none — it is a diff on its own. Give that skill a visual backend: git config anchor.${review_skill:-<skill>}.reviewBackend revdiff" >&2
    editor_emit no-verdict absent "no drafted artifact to edit"
    return
  fi

  if [[ ! -r "$artifact_file" ]]; then
    echo "review-diff.sh: cannot read the drafted artifact at $artifact_file" >&2
    editor_emit no-verdict absent "artifact unreadable"
    return
  fi

  local ed
  ed=$(anchor_editor_resolve)
  if ! anchor_editor_named "$ed"; then
    echo "review-diff.sh: no editor configured — set core.editor, VISUAL, or EDITOR." >&2
    editor_emit no-verdict absent "no editor configured"
    return
  fi

  local original buffer
  original=$(cat "$artifact_file")
  buffer=$(anchor_tmpfile anchor-editor "$(editor_buffer_ext "$artifact_target")")

  {
    printf '%s\n\n' "$original"
    printf '%s\n' "$editor_scissors"
    printf 'Everything below this line is ignored. Save to accept the text above;\n'
    printf 'empty it to abort, and nothing this review gates will happen.\n\n'
    printf '%s\n' "$review_title"
    # The seeded message rides in the details as a `body` row for a viewer's header;
    # here the message is the editable region itself, so the row would be a
    # second copy the user could edit to no effect.
    jq -r '.[] | select(.label != "body") | "  \(.label): \(.value)"' <<<"$review_details_json"
    printf '\n'
    if [[ "$review_mode" == "files" ]]; then
      diff -u "$files_left" "$artifact_file" || true
    else
      git diff "$diff_range" || true
    fi
  } > "$buffer"

  local rc=0
  editor_launch "$ed" "$buffer" || rc=$?

  local saved
  saved=$(sed "/^${editor_scissors}\$/,\$d" "$buffer")
  # Trailing blank lines are the separator this adapter wrote, not the user's text.
  saved=$(printf '%s' "$saved" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
  rm -f "$buffer"

  if [[ "$rc" -ne 0 ]]; then
    editor_emit no-verdict "$rc" "editor exited $rc"
    return
  fi

  if [[ -z "${saved//[[:space:]]/}" ]]; then
    editor_emit no-verdict 0 "artifact emptied — aborted"
    return
  fi

  if [[ "$saved" == "$original" ]]; then
    editor_emit approved 0
    return
  fi

  local edited_json
  edited_json=$(jq -cn --arg t "$artifact_target" --arg o "$original" --arg e "$saved" \
    '[{target:$t, original:$o, edited:$e}]')
  editor_emit approved 0 "" "$edited_json"
}
