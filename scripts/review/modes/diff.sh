#!/usr/bin/env bash
# `diff` mode adapter for review-diff.sh (see SPEC.md "DIFF"). It owns everything
# every diff tool needs alike — finding the binary, putting a terminal up to
# render it in, seeding the header, and shaping the normalized result — and
# delegates the parts that are one tool's own to a tool under tools/.
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_subject       "range" | "files"
#   review_tool       the diff tool to run
#   diff_range           the git range (range mode)
#   diff_staged          1 == review the index against diff_range, not the tree
#   diff_paths           the paths a --local review covers, one per line
#                          (empty: the whole tree)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#   review_annotations   notes to preload, in revdiff's markdown (empty: none)
#   review_seeded        the agent's own notes as JSON, read back as read rather
#                          than as feedback (empty: none)
#   review_reply         the state dir of a reply review (empty: not one)
#   review_untracked     1 == show untracked files beside the diff
#
# A diff tool is a TUI, so it needs a terminal to render, and anchor launches
# review from a background Bash call with no controlling TTY. The terminal comes
# from scripts/lib/review-host.sh, which ranks the hosts it can reach — the same
# dispatcher `edit` mode uses, so the two modes reach equally far.
#
# ## The tool contract
#
# tools/<name>.sh is sourced once the mode is settled and defines:
#
#   diff_tool_caps            the capabilities JSON for this tool
#   diff_tool_install_hint    how to install it, for the `absent` report
#   diff_tool_command <bin> <out_file> <err_file> <desc_file>
#                                print the `sh` command string that runs a review
#   diff_tool_comments <out_file> <desc_file>
#                                parse the tool's answer into the DIFF comments array
#   diff_tool_verdict <rc> <comments_json>
#                                map the tool's exit status onto a verdict, given
#                                the notes the reviewer wrote (a preloaded note
#                                returned as it was is left out). `undecided`, for
#                                a review that ended without one, is reported as
#                                `no-verdict` with raw.exitCode `undecided`, for
#                                the caller to ask about.
#
# and may define, where the default below doesn't fit:
#
#   diff_tool_reports_via_tree  1 == the tool's verdict is the reviewer's
#                                  edits to the working tree, so it can grade
#                                  only a review whose right side *is* the tree
#                                  (default: 0, the tool reports for itself)
#   diff_tool_available <name>  is the tool reachable (default: on PATH)
#   diff_tool_before            run before the tool opens — a tool that
#                                  reads the reviewer's answer out of the working
#                                  tree takes its baseline here
#   diff_tool_cleanup           run after the result is emitted
#   diff_tool_edited            the draft as the reviewer changed it in the tool,
#                                  as editedFields, written over the draft
#                                  (default: the tool doesn't change it, [])
#   diff_tool_shared_note <comment_json>
#                                whether a note sits on the review's shared
#                                context, off its items, where a lone verdict
#                                word decides a review of items (default: no
#                                such place, so only the Review box does)
#
# The statuses a *host* owns — an absent tool, no terminal, a pane that closed
# before the tool reported — never reach the tool: they are not verdicts the
# tool returned, and each would otherwise be re-derived per tool.

# shellcheck source=../../lib/review-host.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/review-host.sh"
# shellcheck source=../../lib/review-difftool.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/review-difftool.sh"

# Emit a `no-verdict` for a cause the host owns, naming it rather than numbering
# it — the number would attribute to the tool a status it never returned.
diff_unavailable() {
  echo "review-diff.sh: $1" >&2
  jq -cn --argjson caps "$diff_tool_caps" --arg b "${review_tool:-}" --arg rc "$2" '{
    mode:"diff", tool:$b, verdict:"no-verdict",
    reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
    capabilities:($caps + {producesVerdict:false}), raw:{exitCode:$rc}}' \
    | { read -r out; echo "REVIEW_VERDICT=no-verdict"; echo "REVIEW_OUTPUT=$out"; }
}

# The adapter that runs <tool>: a name anchor ships an adapter for wins, and
# anything else git can launch as a difftool goes to the adapter that drives
# them all. Empty when neither fits.
diff_tool_file() {
  local tool_dir tool_file
  tool_dir="$(dirname "${BASH_SOURCE[0]}")/../tools"
  tool_file="${tool_dir}/$1.sh"
  if [[ ! -r "$tool_file" && -r "${tool_dir}/difftool.sh" ]] && anchor_difftool_known "$1"; then
    tool_file="${tool_dir}/difftool.sh"
  fi
  [[ ! -r "$tool_file" ]] || printf '%s' "$tool_file"
}

# Start this review over in `edit` mode, on the draft as it now stands, and
# relay that mode's result: the reviewer chose to finish it in their editor.
# Notes they left besides the choice go into the editor's context, so none is
# dropped on the way.
# shellcheck disable=SC2034
diff_relaunch() {
  review_carried_notes=$(jq -r '.[] | "  \(.file // "the review")\(if .startLine then ":\(.startLine)" else "" end): \(.body)"' <<<"$1")
  review_mode="edit"
  review_tool=$(anchor_editor_resolve)
  # edit.sh sources this file for its own switch, so shellcheck is not sent round the loop.
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/edit.sh"
  emit_review
}

# Consumes the review-request variables the dispatcher exports before sourcing
# this adapter; shellcheck can't follow that cross-file.
# shellcheck disable=SC2154
emit_review() {
  local tool_file
  # Nothing named the viewer, and nothing stands in for it. Say which key names
  # one and what anchor recommends putting there, rather than picking a tool the
  # user never chose and reporting its verdict as theirs.
  if [[ -z "${review_tool:-}" ]]; then
    diff_tool_caps='{"producesVerdict":false,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":false}'
    diff_unavailable "no diff viewer configured. Set anchor.diff.tool (or git's own diff.tool) to the viewer you want — anchor recommends revdiff: brew install umputun/apps/revdiff" no-tool
    return
  fi
  tool_file=$(diff_tool_file "$review_tool")
  if [[ -z "$tool_file" ]]; then
    # Resolution keeps a name it could not place so this report can carry it.
    diff_tool_caps='{"producesVerdict":false,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":false}'
    diff_unavailable "no adapter for diff tool '${review_tool}' (looked in $(dirname "${BASH_SOURCE[0]}")/../tools). Set anchor.diff.tool to one anchor ships." unknown-tool
    return
  fi
  # shellcheck source=/dev/null
  source "$tool_file"

  # A request the tool can't carry is refused rather than dropped: preloaded
  # notes that never reach the reviewer read back as notes they deleted.
  if [[ -n "${review_annotations:-}" ]] && [[ "$(jq -r '.preloadsAnnotations // false' <<<"$diff_tool_caps")" != true ]]; then
    diff_unavailable "$review_tool can't preload review notes; this review needs a viewer that can (anchor.diff.tool=revdiff)" annotations-unsupported
    return
  fi
  if [[ "${review_untracked:-0}" -eq 1 ]] && [[ "$(jq -r '.showsUntracked // false' <<<"$diff_tool_caps")" != true ]]; then
    diff_unavailable "$review_tool can't show untracked files; this review needs a viewer that can (anchor.diff.tool=revdiff)" untracked-unsupported
    return
  fi

  # git hands a difftool temp copies of any side that isn't the working tree,
  # so an edit there never reaches a file and the untouched tree reads as
  # approval. The index (a partly staged commit) and a commit range (a CR, the
  # previous commit, the full branch) are both such sides.
  if [[ "${diff_tool_reports_via_tree:-0}" -eq 1 && "$review_subject" == "range" ]]; then
    if [[ "${diff_staged:-0}" -eq 1 ]]; then
      diff_unavailable "$review_tool reports through edits to the working tree, and git opens a staged diff's index side as temp copies, so its verdict on a partly staged commit would be lost; review it with a tool that reads the index and reports itself (anchor.diff.tool=revdiff)" staged-unsupported
      return
    fi
    if [[ "$diff_range" == *..* ]]; then
      diff_unavailable "$review_tool reports through edits to the working tree, and git opens both sides of $diff_range as temp copies, so its verdict would be lost; review a commit range with a tool that reports itself (anchor.diff.tool=revdiff)" range-unsupported
      return
    fi
  fi

  # PATH answers for most tools; one git launches by recipe or by a configured
  # command has its own way of saying whether it is reachable.
  local bin
  if declare -F diff_tool_available >/dev/null; then
    if ! diff_tool_available "$review_tool"; then
      diff_unavailable "$review_tool is not reachable ($diff_tool_install_hint)" absent
      return
    fi
    bin="$review_tool"
  else
    bin=$(command -v "$review_tool" 2>/dev/null || true)
    if [[ -z "$bin" ]]; then
      diff_unavailable "$review_tool is not installed ($diff_tool_install_hint)" absent
      return
    fi
  fi
  if ! anchor_host_available diff; then
    diff_unavailable "$review_tool needs a terminal to render, and this session has nowhere to open one (see $anchor_review_hosts_doc)" no-host
    return
  fi

  # The review's header, seeded so the reviewer reads what is under review beside
  # the diff. Written here rather than per tool: the content is the request's,
  # and only the flag that carries it is the tool's. Plain text, since revdiff
  # highlights its description as markdown without rendering it, leaving `**`
  # and `#` on screen. The body is prose, so it follows the rows as a paragraph.
  local desc_file out_file err_file body
  desc_file=$(mktemp "${TMPDIR:-/tmp}/anchor-review-desc.XXXXXX")
  body=$(jq -r '.[] | select(.label == "body") | .value' <<<"$review_details_json")
  {
    printf '%s\n\n' "$review_title"
    jq -r '[.[] | select(.label != "body")]
      | (map(.label | length) | max) as $w
      | .[] | (($w - (.label | length)) as $pad
        | "  \(.label):\(if $pad > 0 then " " * $pad else "" end) \(.value)")' \
      <<<"$review_details_json"
    if [[ -n "$body" ]]; then printf '\n%s\n' "$body"; fi
  } > "$desc_file"
  out_file=$(mktemp "${TMPDIR:-/tmp}/anchor-review-out.XXXXXX")
  err_file=$(mktemp "${TMPDIR:-/tmp}/anchor-review-err.XXXXXX")

  ! declare -F diff_tool_before >/dev/null || diff_tool_before

  local rc=0 cmd
  cmd=$(diff_tool_command "$bin" "$out_file" "$err_file" "$desc_file")
  anchor_host_run "$cmd" diff || rc=$?

  # A tool's warnings reach stderr on a successful review too, so the capture is
  # replayed only where the run actually failed.
  if [[ "$rc" -ne 0 && "$rc" -ne 10 && -s "$err_file" ]]; then
    cat "$err_file" >&2
  fi

  # The pane never reported, so there is nothing to parse and no status the tool
  # returned. Named the way an absent tool is.
  if [[ "$rc" -eq "$anchor_host_rc_no_result" || "$rc" -eq "$anchor_host_rc_no_pane" ]]; then
    if [[ "$rc" -eq "$anchor_host_rc_no_result" ]]; then
      diff_unavailable "quit the review to finish it — closing its pane or tab takes $review_tool with it before it can report. Nothing was graded; re-run to review again." pane-closed
    else
      diff_unavailable "the review pane could not be opened" no-pane
    fi
    rm -f "$out_file" "$err_file" "$desc_file"
    ! declare -F diff_tool_cleanup >/dev/null || diff_tool_cleanup
    return
  fi

  local comments returned verdict
  comments=$(diff_tool_comments "$out_file" "$desc_file")
  returned="$comments"
  # The agent's own notes (a reply, or what it said about its changes) come back
  # among the reviewer's. One returned as it was seeded was read, and one deleted
  # was read and set aside; only an edited or a new note is the reviewer
  # answering.
  local seeded="${review_seeded:-}"
  [[ -z "${review_reply:-}" ]] || seeded="$review_reply/notes.json"
  if [[ -n "$seeded" ]]; then
    comments=$(jq -c --slurpfile seeded "$seeded" '
      def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
      [.[] | . as $c
        | select(any($seeded[0][];
            .file == $c.file
            and (if .marker == "file" then $c.target == "file" else .line == $c.startLine end)
            and (.body | norm) == ($c.body | norm)) | not)]' <<<"$comments")
  fi
  # revdiff returns every preloaded note it still holds, so a note returned as
  # it was preloaded is not the reviewer answering, and a review that returns
  # only those has said nothing.
  local answered="$comments" preloaded="[]" exit_name="" lone
  if [[ -n "${review_annotations:-}" ]]; then
    preloaded=$(diff_tool_comments "$review_annotations" "$desc_file")
    answered=$(jq -c --argjson pre "$preloaded" '
      def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
      def key: [.file, .target, .startLine, (.body | norm)];
      ($pre | map(key)) as $k | [.[] | select(key as $c | $k | index([$c]) | not)]' <<<"$comments")
  fi
  # A review whose one note says only a verdict word chooses as a note on the
  # Review box does, wherever it sits, except where a preloaded note sat:
  # there it answers that note. In a review of items (a batch, a round, which
  # preload notes and write their own context), answers on the items' notes
  # don't count against it, and only a note on the shared file decides, since a
  # word on an item (a batch's `reject`) is about that item.
  local items=false
  [[ -z "${review_annotations:-}" || -n "${review_seeded:-}" || -n "${review_reply:-}" ]] || items=true
  lone=$(jq -c --argjson pre "$preloaded" --argjson items "$items" '
    def word: ascii_downcase | gsub("^\\s+"; "") | gsub("[\\s.!]+$"; "");
    def choice: (.body | word) as $w
      | if ($w | IN("lgtm", "ship it", "approve", "accept")) then "accept"
        elif ($w | IN("reject", "stop", "abort", "cancel")) then "reject" else null end;
    def atpre($at): . as $n | $at | index([[$n.file, $n.target, $n.startLine]]) != null;
    ($pre | map([.file, .target, .startLine])) as $at
    | (if $items then map(select(atpre($at) | not)) else . end) as $own
    | if ($own | length) == 1 and $own[0].target != "verdict" and ($own[0] | choice) != null
         and ($own[0] | atpre($at) | not)
      then {note: $own[0], choice: ($own[0] | choice)} else null end' <<<"$answered")
  if [[ "$lone" != null && "$items" == true ]]; then
    if ! declare -F diff_tool_shared_note >/dev/null || ! diff_tool_shared_note "$(jq -c .note <<<"$lone")"; then
      lone=null
    fi
  fi
  if [[ "$lone" != null ]]; then
    # shellcheck disable=SC2016
    local as_choice='map(if [.file, .target, .startLine, .body] == ($l.note | [.file, .target, .startLine, .body])
                         then . + {target: "verdict", choice: $l.choice} else . end)'
    answered=$(jq -c --argjson l "$lone" "$as_choice" <<<"$answered")
    comments=$(jq -c --argjson l "$lone" "$as_choice" <<<"$comments")
    returned=$(jq -c --argjson l "$lone" "$as_choice" <<<"$returned")
  fi
  verdict=$(diff_tool_verdict "$rc" "$answered")
  # A draft the reviewer changed in the tool goes back for approval as changed,
  # since approving it in the tool was approving the text before the edit was
  # read back (CONFIRM-08).
  local edited='[]'
  ! declare -F diff_tool_edited >/dev/null || edited=$(diff_tool_edited)
  if [[ "$edited" != '[]' && "$verdict" == approved ]]; then
    echo "review-diff.sh: the draft was edited in $review_tool, so it comes back for approval as edited" >&2
    verdict=changes-requested
  fi
  if [[ "$verdict" == relaunch ]]; then
    rm -f "$out_file" "$err_file" "$desc_file"
    ! declare -F diff_tool_cleanup >/dev/null || diff_tool_cleanup
    diff_relaunch "$(jq -c 'map(select(.target != "verdict"))' <<<"$answered")"
    return
  fi
  if [[ "$verdict" == undecided ]]; then
    echo "review-diff.sh: the review closed with no verdict chosen; ask the reviewer whether to accept, reject, or reopen it" >&2
    verdict=no-verdict exit_name=undecided
  fi
  # The choice is the verdict; a caller reading the notes as items never sees it.
  returned=$(jq -c 'map(select(.target != "verdict"))' <<<"$returned")
  # Saved only where the next review can carry the replies.
  if [[ "$verdict" == changes-requested ]] && declare -F review_state_save >/dev/null \
     && [[ "$(jq -r '.preloadsAnnotations // false' <<<"$diff_tool_caps")" == true ]]; then
    review_state_save "$comments"
  fi

  local out
  out=$(jq -cn \
    --arg v "$verdict" --arg b "$review_tool" \
    --argjson caps "$diff_tool_caps" \
    --argjson comments "$comments" --argjson edited "$edited" \
    --argjson rc "$rc" --arg name "$exit_name" '
    {
      mode:"diff",
      tool:$b,
      verdict:$v,
      reviewCompleteness:null,
      reviewer:null,
      comments:$comments,
      editedFields:$edited,
      capabilities:$caps,
      raw:{exitCode:(if $name == "" then $rc else $name end)}
    }')

  rm -f "$out_file" "$err_file" "$desc_file"
  ! declare -F diff_tool_cleanup >/dev/null || diff_tool_cleanup
  # The set of notes the reviewer left, kept beside the ones that were preloaded
  # so a caller compares the two from files rather than from this output line.
  if [[ -n "${review_annotations:-}" ]]; then
    local returned_file="${review_annotations%.md}.returned.json"
    printf '%s\n' "$returned" > "$returned_file"
    echo "REVIEW_RETURNED=$returned_file"
  fi
  echo "REVIEW_VERDICT=$verdict"
  echo "REVIEW_OUTPUT=$out"
}
