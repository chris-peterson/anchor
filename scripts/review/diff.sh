#!/usr/bin/env bash
# `diff` mode adapter for review-diff.sh (see SPEC.md "DIFF"). It owns everything
# every diff tool needs alike — finding the binary, putting a terminal up to
# render it in, seeding the header, and shaping the normalized result — and
# delegates the parts that are one tool's own to a backend under backends/.
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_subject       "range" | "files"
#   review_backend       the diff tool to run
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#
# A diff tool is a TUI, so it needs a terminal to render, and anchor launches
# review from a background Bash call with no controlling TTY. The terminal is a
# split of the calling iTerm2 session, opened by scripts/lib/split-run.sh — the
# same runner `edit` mode uses.
#
# ## The backend contract
#
# backends/<name>.sh is sourced once the mode is settled and defines:
#
#   diff_backend_caps            the capabilities JSON for this tool
#   diff_backend_install_hint    how to install it, for the `absent` report
#   diff_backend_command <bin> <out_file> <err_file> <desc_file>
#                                print the `sh` command string that runs a review
#   diff_backend_comments <out_file>
#                                parse the tool's answer into the DIFF comments array
#   diff_backend_verdict <rc> <comments_json>
#                                map the tool's exit status onto a verdict
#
# and may define, where the default below doesn't fit:
#
#   diff_backend_available <name>  is the tool reachable (default: on PATH)
#   diff_backend_before            run before the tool opens — a backend that
#                                  reads the reviewer's answer out of the working
#                                  tree takes its baseline here
#   diff_backend_cleanup           run after the result is emitted
#
# The statuses a *host* owns — an absent tool, no terminal, a pane that closed
# before the tool reported — never reach the backend: they are not verdicts the
# tool returned, and each would otherwise be re-derived per tool.

# shellcheck source=../lib/split-run.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/split-run.sh"
# shellcheck source=../lib/review-difftool.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/review-difftool.sh"

# Emit a `no-verdict` for a cause the host owns, naming it rather than numbering
# it — the number would attribute to the tool a status it never returned.
diff_unavailable() {
  echo "review-diff.sh: $1" >&2
  jq -cn --argjson caps "$diff_backend_caps" --arg b "${review_backend:-}" --arg rc "$2" '{
    mode:"diff", backend:$b, verdict:"no-verdict",
    reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
    capabilities:($caps + {producesVerdict:false}), raw:{exitCode:$rc}}' \
    | { read -r out; echo "REVIEW_VERDICT=no-verdict"; echo "REVIEW_OUTPUT=$out"; }
}

# Consumes the review-request variables the dispatcher exports before sourcing
# this adapter; shellcheck can't follow that cross-file.
# shellcheck disable=SC2154
emit_review() {
  # A name anchor ships an adapter for wins; anything else git can launch as a
  # difftool goes to the adapter that drives them all, so the user's own
  # `diff.tool` needs no adapter of its own.
  local backend_dir backend_file
  backend_dir="$(dirname "${BASH_SOURCE[0]}")/backends"
  backend_file="${backend_dir}/${review_backend}.sh"
  if [[ ! -r "$backend_file" && -r "${backend_dir}/difftool.sh" ]] \
     && anchor_difftool_known "$review_backend"; then
    backend_file="${backend_dir}/difftool.sh"
  fi
  if [[ ! -r "$backend_file" ]]; then
    # Resolution keeps a name it could not place so this report can carry it.
    diff_backend_caps='{"producesVerdict":false,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":false}'
    diff_unavailable "no adapter for diff backend '${review_backend}' (looked in $(dirname "$backend_file")). Set anchor.diff.backend to one anchor ships." unknown-backend
    return
  fi
  # shellcheck source=/dev/null
  source "$backend_file"

  # PATH answers for most tools; one git launches by recipe or by a configured
  # command has its own way of saying whether it is reachable.
  local bin
  if declare -F diff_backend_available >/dev/null; then
    if ! diff_backend_available "$review_backend"; then
      diff_unavailable "$review_backend is not reachable ($diff_backend_install_hint)" absent
      return
    fi
    bin="$review_backend"
  else
    bin=$(command -v "$review_backend" 2>/dev/null || true)
    if [[ -z "$bin" ]]; then
      diff_unavailable "$review_backend is not installed ($diff_backend_install_hint)" absent
      return
    fi
  fi
  if ! anchor_split_available; then
    diff_unavailable "$review_backend needs a terminal to render, and this session has nowhere to open one — it opens in a split of the calling iTerm2 session" no-host
    return
  fi

  # The review's header, seeded so the reviewer reads what is under review beside
  # the diff. Written here rather than per backend: the content is the request's,
  # and only the flag that carries it is the tool's.
  local desc_file out_file err_file
  desc_file=$(mktemp "${TMPDIR:-/tmp}/anchor-review-desc.XXXXXX")
  {
    printf '# %s\n\n' "$review_title"
    jq -r '.[] | "- **\(.label):** \(.value)"' <<<"$review_details_json"
  } > "$desc_file"
  out_file=$(mktemp "${TMPDIR:-/tmp}/anchor-review-out.XXXXXX")
  err_file=$(mktemp "${TMPDIR:-/tmp}/anchor-review-err.XXXXXX")

  ! declare -F diff_backend_before >/dev/null || diff_backend_before

  local rc=0 cmd
  cmd=$(diff_backend_command "$bin" "$out_file" "$err_file" "$desc_file")
  anchor_split_run "$cmd" || rc=$?

  # A tool's warnings reach stderr on a successful review too, so the capture is
  # replayed only where the run actually failed.
  if [[ "$rc" -ne 0 && "$rc" -ne 10 && -s "$err_file" ]]; then
    cat "$err_file" >&2
  fi

  # The pane never reported, so there is nothing to parse and no status the tool
  # returned. Named the way an absent tool is.
  if [[ "$rc" -eq "$anchor_split_rc_no_result" || "$rc" -eq "$anchor_split_rc_no_pane" ]]; then
    if [[ "$rc" -eq "$anchor_split_rc_no_result" ]]; then
      diff_unavailable "quit the review to finish it — closing its pane or tab takes $review_backend with it before it can report. Nothing was graded; re-run to review again." pane-closed
    else
      diff_unavailable "the review pane could not be opened" no-pane
    fi
    rm -f "$out_file" "$err_file" "$desc_file"
    ! declare -F diff_backend_cleanup >/dev/null || diff_backend_cleanup
    return
  fi

  local comments verdict
  comments=$(diff_backend_comments "$out_file")
  verdict=$(diff_backend_verdict "$rc" "$comments")

  local out
  out=$(jq -cn \
    --arg v "$verdict" --arg b "$review_backend" \
    --argjson caps "$diff_backend_caps" \
    --argjson comments "$comments" \
    --argjson rc "$rc" '
    {
      mode:"diff",
      backend:$b,
      verdict:$v,
      reviewCompleteness:null,
      reviewer:null,
      comments:$comments,
      editedFields:[],
      capabilities:$caps,
      raw:{exitCode:$rc}
    }')

  rm -f "$out_file" "$err_file" "$desc_file"
  ! declare -F diff_backend_cleanup >/dev/null || diff_backend_cleanup
  echo "REVIEW_VERDICT=$verdict"
  echo "REVIEW_OUTPUT=$out"
}
