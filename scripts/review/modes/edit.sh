#!/usr/bin/env bash
# `edit` mode adapter for review-diff.sh (see SPEC.md "DIFF"). One adapter
# serves the whole mode: the editor it drives is the mode's tool, resolved by
# the dispatcher and handed over in review_tool, so a different editor is not
# a different adapter.
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_subject       "range" | "files"
#   review_tool       the editor to open
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#   message_file         the drafted commit message (range mode, --message-file)
#   review_skill         the invoking skill, when the caller passed --skill
#
# `diff` mode asks the reviewer to *comment* on a draft and anchor rewrites from
# the comments. This mode is the other shape of that step: it opens
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
#   closed without saving, emptied, or exited non-zero (vim's `:cq`) ->
#                            no-verdict, which already halts the flow and is
#                            never read as approval
#
# The save is the answer. It is one keystroke either way, it is an act rather
# than the absence of one, and it survives whatever happened to the terminal
# afterwards — so a draft saved into a pane that was then closed is still the
# reviewer's answer, where the exit status alone would have thrown it away.
# Where nothing was saved, the causes ride out as named `raw.exitCode` values —
# `unsaved`, `pane-closed`, `no-pane`, `no-host` — so a consumer can say what
# happened rather than quote a status the editor never returned.
#
# An editor carries one artifact, so a review with no drafted artifact (a
# diff-only range review) is `no-verdict` with the cause on stderr rather than a
# silent pass — set a visual tool for those skills.
#
# Editor resolution is in lib/review-editor.sh; host selection in
# lib/review-host.sh. Both have a second caller — the dispatcher's --probe, and
# `diff` mode.
# shellcheck source=../../lib/review-editor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/review-editor.sh"
# shellcheck source=../../lib/review-host.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/review-host.sh"
# shellcheck source=../../lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/tmpfile.sh"

editor_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":true,"editableDescription":true,"sideMarkers":false}'

# Cut point between the editable artifact and the read-only context below it.
# git's own marker, minus the leading `#`, since `#` lines are kept here.
editor_scissors='------------------------ >8 ------------------------'

editor_emit() {
  local verdict="$1" rc="$2" note="${3:-}" edited_json="${4:-[]}"
  local out
  out=$(jq -cn \
    --arg v "$verdict" --arg n "$note" --arg b "${review_tool:-}" \
    --argjson caps "$editor_caps" --argjson edited "$edited_json" \
    --arg rc "$rc" '
    {
      mode:"edit",
      tool:$b,
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

# Nothing to open the editor in. Its own status, distinct from the two a host
# reports, so the three causes reach `emit_review` apart from each other and none
# of them is quoted back to the user as an editor's exit code.
editor_rc_no_host=123

# Open $2 in the resolved editor $1 and return the editor's exit status, in
# whichever host the dispatcher picked for this session — or one of the statuses
# above, where the host never got the editor on screen.
editor_launch() {
  local ed="$1" file="$2" rc=0

  # The launcher takes the file rather than a command string, so it is opened
  # here rather than through a host of its own.
  if [[ -n "${ANCHOR_EDITOR_LAUNCHER:-}" ]]; then
    "$ANCHOR_EDITOR_LAUNCHER" "$file" || rc=$?
    return "$rc"
  fi

  if ! anchor_host_available edit "$ed"; then
    echo "review-diff.sh: no way to open '$ed' — a terminal editor needs a terminal, and this session has none. Run inside tmux, configure a blocking GUI editor (git config core.editor 'code --wait'), or point ANCHOR_EDITOR_LAUNCHER at a script that opens one." >&2
    return "$editor_rc_no_host"
  fi

  anchor_host_run "$ed $(anchor_host_sq "$file")" edit "$ed" || rc=$?
  return "$rc"
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

  if [[ "$review_subject" == "files" ]]; then
    artifact_file="$files_right"
    [[ -n "$artifact_target" ]] || artifact_target="description"
  elif [[ -n "${message_file:-}" ]]; then
    artifact_file="$message_file"
    [[ -n "$artifact_target" ]] || artifact_target="commit-message"
  else
    echo "review-diff.sh: edit mode edits a drafted artifact, and this review has none — it is a diff on its own. Put that skill in diff mode: git config anchor.${review_skill:-<skill>}.reviewMode diff" >&2
    editor_emit no-verdict absent "no drafted artifact to edit"
    return
  fi

  if [[ ! -r "$artifact_file" ]]; then
    echo "review-diff.sh: cannot read the drafted artifact at $artifact_file" >&2
    editor_emit no-verdict absent "artifact unreadable"
    return
  fi

  local ed="${review_tool:-}"
  [[ -n "$ed" ]] || ed=$(anchor_editor_resolve)
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
    printf 'Everything below this line is ignored. Save to approve the text above,\n'
    printf 'unchanged if it already reads right. Quit without saving to abort, and\n'
    printf 'nothing this review gates will happen.\n\n'
    printf '%s\n' "$review_title"
    # The seeded message rides in the details as a `body` row for a viewer's header;
    # here the message is the editable region itself, so the row would be a
    # second copy the user could edit to no effect.
    jq -r '.[] | select(.label != "body") | "  \(.label): \(.value)"' <<<"$review_details_json"
    printf '\n'
    if [[ "$review_subject" == "files" ]]; then
      diff -u "$files_left" "$artifact_file" || true
    else
      git diff "$diff_range" || true
    fi
  } > "$buffer"

  # Did the editor write? The reference is stamped *from the buffer* (`touch -r`),
  # so the two are equal going in and `-nt` is false until something writes; any
  # write at all lands the buffer in the present and wins, whether the editor
  # wrote in place or renamed a new file over the top. Equal-by-construction is
  # what makes the test decisive at every timestamp granularity — a reference
  # stamped "now" instead races the write it is meant to detect, and loses that
  # race wherever mtimes compare by the second (macOS ships bash 3.2, which does).
  #
  # Comparing content instead would be simpler and wrong: an editor that saves the
  # draft unchanged writes the same bytes as one that never opened, and those are
  # opposite verdicts here — approval versus abort.
  local write_ref
  write_ref=$(anchor_tmpfile anchor-editor-ref txt)
  : > "$write_ref"
  touch -t 200001010000 "$buffer"
  touch -r "$buffer" "$write_ref"

  local rc=0
  editor_launch "$ed" "$buffer" || rc=$?

  local wrote=1
  [[ "$buffer" -nt "$write_ref" ]] || wrote=0
  rm -f "$write_ref"

  local saved
  saved=$(sed "/^${editor_scissors}\$/,\$d" "$buffer")
  # Trailing blank lines are the separator this adapter wrote, not the user's text.
  saved=$(printf '%s' "$saved" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
  rm -f "$buffer"

  # A failure the host owns rides out as a named cause the way the viewer
  # tool's `absent` / `no-host` do, not as a number. Quoting one back as the
  # editor's exit code names a step that never happened — the editor was never
  # asked, or was still running when its terminal went away — and leaves the
  # user with a status to interpret instead of the thing to do next.
  case "$rc" in
    0) ;;
    "$editor_rc_no_host")
      editor_emit no-verdict no-host "no way to open the editor"
      return ;;
    "$anchor_host_rc_no_pane")
      editor_emit no-verdict no-pane "the review pane could not be opened"
      return ;;
    "$anchor_host_rc_no_result")
      # The pane went away before the editor could report its status. What the
      # editor did before that is on disk, so a saved buffer is graded like any
      # other and only an unsaved one is a review that never happened.
      if [[ "$wrote" -eq 0 ]]; then
        echo "review-diff.sh: the review pane closed before anything was saved — closing a pane or tab takes the editor with it. Your draft is intact; re-run to review it again." >&2
        editor_emit no-verdict pane-closed "the review pane closed before anything was saved"
        return
      fi
      ;;
    *)
      editor_emit no-verdict "$rc" "editor exited $rc"
      return ;;
  esac

  if [[ "$wrote" -eq 0 ]]; then
    # A GUI editor invoked without its wait flag returns the instant it hands the
    # file over, so nothing is written and the reviewer never saw a window. That
    # is indistinguishable here from someone choosing not to save, and only one
    # of the two has something to do about it — so where anchor knows the flag,
    # it names it rather than reporting a decision the user never made.
    local wait_flag
    wait_flag=$(anchor_editor_wait_flag "$ed")
    if [[ -n "$wait_flag" ]] && ! anchor_editor_blocking "$ed"; then
      echo "review-diff.sh: '$ed' returned without waiting, so there was nothing to save — it needs $wait_flag to hold the review open. Set it: git config core.editor '$ed $wait_flag'" >&2
      editor_emit no-verdict unsaved "$ed returned without waiting — needs $wait_flag"
      return
    fi
    echo "review-diff.sh: the editor closed without saving, so nothing was approved — saving is how a draft is approved, unchanged if it already reads right. Nothing this review gated has happened; re-run to review it again." >&2
    editor_emit no-verdict unsaved "closed without saving"
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
