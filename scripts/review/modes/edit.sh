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
#   diff_staged          1 == the index against diff_range, not the tree
#   diff_paths           the paths a --local review covers, one per line
#                          (empty: the whole tree)
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
#   exited 2 (`ZX`)       -> rejected, whatever was saved
#   saved emptied         -> rejected
#   exited 3 (`ZD`)       -> the review reopens in `diff` mode on the draft as
#                            saved, and returns that mode's verdict, carrying
#                            any edit made before the switch in editedFields
#   closed without saving -> no-verdict, `undecided`, for the caller to ask about
#   exited non-zero otherwise (vim's `:cq`)
#                         -> no-verdict, since a failing editor exits the same
#                            way; never read as approval
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
#
# Helix and Vim get the three answers as chords for the review (`ZZ`, `ZX`,
# `ZD`, after Vim's own `ZZ`), so ending the review is a deliberate key pair
# rather than an exit code typed at a prompt: Helix through a workspace
# `.helix/config.toml` in the buffer's directory, which it merges over the
# user's own config, and Vim through buffer-local maps on the command line.
# shellcheck source=../../lib/review-editor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/review-editor.sh"
# shellcheck source=../../lib/review-host.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/review-host.sh"
# shellcheck source=../../lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/tmpfile.sh"
# shellcheck source=../../lib/callout.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/callout.sh"
# shellcheck source=../../lib/hints.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/hints.sh"

editor_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":true,"editableDescription":true,"sideMarkers":false}'

# Cut point between the editable artifact and the read-only context below it.
# A commit message gets git's own marker, `#` and all, in a buffer named the way
# git names its own, so the editor's gitcommit mode greys the context and
# colours the diff. A markdown draft gets the marker without the `#`, since `#`
# is a heading there, and its context sits in an HTML comment instead.
editor_scissors='------------------------ >8 ------------------------'
editor_commit_scissors="# $editor_scissors"

# What the reviewer reads past the draft: how to answer, then the flow that
# opened the review and what approving hands it, then what is under review.
# The seeded message rides in the details as a `body` row for a viewer's header;
# here the message is the editable region itself, so the row would be a second
# copy the user could edit to no effect.
# shellcheck disable=SC2154
editor_context() {
  local viewer chords=0 cta
  ! anchor_hints_on edit || ! editor_chords "$1" || chords=1
  viewer=$(editor_viewer)
  if [[ "$chords" -eq 1 ]]; then
    cta="\`ZZ\` approve the text above the line, as saved
\`ZX\` reject it (exit code $editor_rc_reject): nothing this review gates happens"
    [[ -z "$viewer" ]] || cta+="
\`ZD\` ask for changes in $viewer (saves, then exit code $editor_rc_annotate)"
    cta+="
Quit without saving, and you're asked what to do.

$(anchor_hints_off)"
  else
    cta="Save to approve the text above the line, unchanged if it already reads right.

To reject it, quit with exit code $editor_rc_reject, and nothing this review gates will happen."
    [[ -z "$viewer" ]] || cta+="

To ask for changes instead, save, then quit with exit code $editor_rc_annotate, and the saved draft opens in $viewer to annotate."
    cta+="

Quit without saving, and you're asked what to do."
  fi
  printf 'Everything below the line above is ignored.\n'
  anchor_box "$cta"
  printf '\n'
  jq -r '[.[] | select(.label == "opened by" or .label == "next")]
    | if length == 0 then empty else
      ((map(.label | length) | max) as $w
       | (.[] | (($w - (.label | length)) as $pad
         | "  \(.label):\(if $pad > 0 then " " * $pad else "" end) \(.value)")), "")
      end' <<<"$review_details_json"
  printf '%s\n' "$review_title"
  jq -r '.[] | select(.label != "body" and .label != "opened by" and .label != "next")
    | "  \(.label): \(.value)"' <<<"$review_details_json"
  [[ -z "${review_carried_notes:-}" ]] || printf '\nYour notes from the review you relaunched:\n%s\n' "$review_carried_notes"
}

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

# The buffer's file name, which is what an editor's status line shows, so it
# says which object is under review: its reference where the caller passed one
# (`--name`), else the repo, branch, and artifact. Two sessions can
# review the same artifact at once; each buffer gets a directory of its own, so
# the names never meet on disk.
editor_buffer_name() {
  local name="$1" repo branch where=""
  if [[ -n "${files_name:-}" ]]; then
    printf '%s.%s' "$files_name" "$(editor_buffer_ext "$1")"
    return
  fi
  if repo=$(git rev-parse --show-toplevel 2>/dev/null); then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    where="${repo##*/}@${branch//\//-}"
  fi
  if [[ "$1" == commit-message ]]; then
    printf '%s/COMMIT_EDITMSG' "${where:-commit}"
    return
  fi
  printf '%s%s.%s' "${where:+$where.}" "$name" "$(editor_buffer_ext "$1")"
}

# The editor's own name, without its path or arguments.
editor_name() {
  local name="${1%% *}"
  printf '%s' "${name##*/}"
}

# Whether editor $1 gets the review's chords.
editor_chords() {
  case "$(editor_name "$1")" in
    hx|helix|vi|vim|nvim) return 0 ;;
    *)                 return 1 ;;
  esac
}

# Helix's status line shows a path relative to its working directory, so it
# starts in the buffer's own directory and shows the buffer's name rather than
# a temp path. That directory is also where Helix finds the review's chords.
editor_open_args() {
  local ed="$1" dir="$2"
  case "$(editor_name "$ed")" in
    hx|helix)
      mkdir -p "$dir/.helix"
      printf '[keys.normal.Z]\nZ = ":write-quit"\nX = ":cquit %s"\nD = [":write", ":cquit %s"]\n' \
        "$editor_rc_reject" "$editor_rc_annotate" > "$dir/.helix/config.toml"
      printf -- '-w %s ' "$(anchor_host_sq "$dir")" ;;
    vi|vim|nvim)
      printf -- '-c %s -c %s ' \
        "$(anchor_host_sq "nnoremap <buffer> ZX :cquit $editor_rc_reject<CR>")" \
        "$(anchor_host_sq "nnoremap <buffer> ZD :write<Bar>cquit $editor_rc_annotate<CR>")" ;;
  esac
}

# Nothing to open the editor in. Its own status, distinct from the two a host
# reports, so the three causes reach `emit_review` apart from each other and none
# of them is quoted back to the user as an editor's exit code.
editor_rc_no_host=123

# The status a reviewer quits with to reject the draft.
editor_rc_reject=2

# The status a reviewer quits with to annotate the draft in the diff viewer
# rather than edit it: for a change they want made rather than make themselves.
editor_rc_annotate=3

# The viewer a `diff` review would open, resolved the way the dispatcher
# resolves it; empty when none is named. Call it in a subshell, since it
# resolves over the dispatcher's settled state.
# shellcheck disable=SC2034,SC2154
editor_viewer() {
  resolved_mode="diff"; tool_override=""
  resolve_tool
  printf '%s' "$resolved_tool"
}

# Reopen this review in `diff` mode on draft $3, the artifact $1 as the reviewer
# left it, and relay that mode's result. What they edited before switching
# rides back in editedFields, so the draft a skill revises or adopts is the one
# they annotated.
# shellcheck disable=SC2034,SC2154
editor_annotate() {
  local target="$1" original="$2" draft="$3" draft_file empty_file="" edited='[]' line
  draft_file=$(anchor_tmpfile anchor-annotate "$(editor_buffer_ext "$target")")
  printf '%s\n' "$draft" > "$draft_file"
  if [[ "$review_subject" == files ]]; then
    files_right="$draft_file"
    if [[ ! -f "${files_left:-}" ]]; then
      empty_file=$(anchor_tmpfile anchor-annotate-empty "$(editor_buffer_ext "$target")")
      : > "$empty_file"
      files_left="$empty_file"
    fi
  else
    message_file="$draft_file"
  fi
  [[ "$draft" == "$original" ]] || edited=$(jq -cn --arg t "$target" --arg o "$original" --arg e "$draft" \
    '[{target:$t, original:$o, edited:$e}]')

  review_mode="diff"
  review_tool=$(editor_viewer)
  # shellcheck source=diff.sh
  source "$(dirname "${BASH_SOURCE[0]}")/diff.sh"
  while IFS= read -r line; do
    case "$line" in
      REVIEW_OUTPUT=*) printf 'REVIEW_OUTPUT=%s\n' "$(jq -c --argjson e "$edited" '.editedFields = $e' <<<"${line#REVIEW_OUTPUT=}")" ;;
      *)               printf '%s\n' "$line" ;;
    esac
  done < <(emit_review)
  rm -f "$draft_file" "$empty_file"
}

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
    echo "review-diff.sh: no way to open '$ed' — a terminal editor needs a terminal, and this session has none. Configure a blocking GUI editor (git config core.editor 'code --wait'), or see where a review can open: $anchor_review_hosts_doc" >&2
    return "$editor_rc_no_host"
  fi

  # A COMMIT_EDITMSG sits in a directory named for its repo and branch, and the
  # editor starts above it so the status line carries both.
  local wdir="${file%/*}"
  [[ "${file##*/}" != COMMIT_EDITMSG ]] || wdir="${wdir%/*}"
  anchor_host_run "$ed $(editor_open_args "$ed" "$wdir")$(anchor_host_sq "$file")" edit "$ed" || rc=$?
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
  artifact_target=$(anchor_artifact_target)

  if [[ "$review_subject" == "files" ]]; then
    artifact_file="$files_right"
    [[ -n "$artifact_target" ]] || artifact_target="description"
  elif [[ -n "${message_file:-}" ]]; then
    artifact_file="$message_file"
    [[ -n "$artifact_target" ]] || artifact_target="commit-message"
  else
    echo "review-diff.sh: --mode edit asks to edit a drafted artifact, and this review has none — it is a diff on its own. Nothing defaults here: a subject with no artifact resolves to diff, so this only follows an explicit --mode edit. Launch it with --mode diff, or drop --mode and let the subject settle it." >&2
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

  local original buffer_dir buffer
  original=$(cat "$artifact_file")
  buffer_dir=$(anchor_tmpdir anchor-editor)
  buffer="$buffer_dir/$(editor_buffer_name "$artifact_target")"
  mkdir -p "${buffer%/*}"

  {
    printf '%s\n\n' "$original"
    if [[ "$artifact_target" == commit-message ]]; then
      printf '%s\n' "$editor_commit_scissors" "# Do not modify or remove the line above."
      editor_context "$ed" | sed -e 's/^/# /' -e 's/^# $/#/'
    else
      printf '%s\n<!--\n' "$editor_scissors"
      editor_context "$ed" | sed 's/-->/-- >/g'
      printf -- '-->\n'
    fi
    printf '\n'
    if [[ "$review_subject" == "files" ]]; then
      diff -u --label current --label draft "$files_left" "$artifact_file" || true
    else
      local -a specs=()
      local spec
      while IFS= read -r spec; do specs+=("$spec"); done < <(anchor_diff_specs)
      if [[ "${diff_staged:-0}" -eq 1 ]]; then git diff --cached "$diff_range" -- "${specs[@]+"${specs[@]}"}" || true
      else git diff "$diff_range" -- "${specs[@]+"${specs[@]}"}" || true; fi
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
  saved=$(sed -E "/^(# )?${editor_scissors}\$/,\$d" "$buffer")
  # Trailing blank lines are the separator this adapter wrote, not the user's text.
  saved=$(printf '%s' "$saved" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
  rm -rf "$buffer_dir"

  if [[ "$rc" == "$editor_rc_annotate" ]]; then
    local draft="$original"
    [[ "$wrote" -eq 0 || -z "${saved//[[:space:]]/}" ]] || draft="$saved"
    editor_annotate "$artifact_target" "$original" "$draft"
    return
  fi

  # A failure the host owns rides out as a named cause the way the viewer
  # tool's `absent` / `no-host` do, not as a number. Quoting one back as the
  # editor's exit code names a step that never happened — the editor was never
  # asked, or was still running when its terminal went away — and leaves the
  # user with a status to interpret instead of the thing to do next.
  case "$rc" in
    0) ;;
    "$editor_rc_reject")
      editor_emit rejected "$rc" "rejected"
      return ;;
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
    echo "review-diff.sh: the review closed with no verdict chosen; ask the reviewer whether to accept, reject, or reopen it" >&2
    editor_emit no-verdict undecided "closed without saving"
    return
  fi

  if [[ -z "${saved//[[:space:]]/}" ]]; then
    editor_emit rejected 0 "artifact emptied"
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
