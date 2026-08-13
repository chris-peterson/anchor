#!/usr/bin/env bash
# git-difftool backend adapter for review-diff.sh (see SPEC.md "DIFF").
#
# Drives whatever tool git resolves, so the changes reach the screen. That tool
# speaks no contract of its own, so the result is always the DIFF-10 shape —
# backend `difftool`, `producesVerdict` false, verdict `no-verdict` — and the
# caller asks the user directly.
#
# Selectable, never automatic. This was the bottom rung of the install ladder
# until the rung was measured against what it produces: a difftool review ends
# in the same chat question a missing viewer would have asked, having first
# shown the user a diff nobody can grade. Asking "you saw it — approve?" off the
# back of that is the rubber stamp the verdict contract exists to prevent, so a
# machine with no viewer now reaches the fallback ladder directly
# (guides/review-fallback.md) and this adapter runs only when asked for by name.
#
# The emitted `backend` is `difftool` rather than `git`: the adapter is named
# for what it drives, the contract value names the case a consumer branches on,
# and DIFF-10 fixed that value before this file existed.
#
# This role used to belong to moor's adapter, which drives `git difftool` on its
# way to reading moor's sidecar and so degraded into it for free. That made
# `moor` mean two things — a backend the user selects, and the fallback nobody
# selects — and the reason line 294 of the dispatcher read oddly. Splitting them
# leaves moor's adapter meaning only moor.
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_mode          "range" | "files"
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#
# It reads no header: `git difftool` has nowhere to put a title or detail rows,
# which is part of what makes this a degraded review rather than a peer of the
# other backends.

# Nothing here can produce a verdict, so the capabilities are false across the
# board rather than optimistic about the tool that happens to be configured.
git_caps='{"producesVerdict":false,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":false}'

git_emit() {
  local reason="$1"
  local out
  out=$(jq -cn --argjson caps "$git_caps" --arg ec "$reason" '{
    backend:"difftool", verdict:"no-verdict",
    reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
    capabilities:$caps, raw:{exitCode:$ec}}')
  echo "REVIEW_VERDICT=no-verdict"
  echo "REVIEW_OUTPUT=$out"
}

# Consumes the review-request variables the dispatcher exports before sourcing
# this adapter; shellcheck can't follow that cross-file.
# shellcheck disable=SC2154
emit_review() {
  # With neither key set, `git difftool` falls back to vimdiff, which waits on a
  # terminal that a CI job hasn't got — the run hangs until it is cancelled
  # instead of reporting. Say so rather than launching into it.
  if ! git config --get diff.tool >/dev/null 2>&1 && \
     ! git config --get merge.tool >/dev/null 2>&1; then
    echo "review-diff.sh: no difftool configured (set diff.tool or merge.tool, or install a review backend)" >&2
    git_emit "absent"
    return
  fi

  if [[ "$review_mode" == "files" ]]; then
    # Two arbitrary paths aren't a git range; --no-index diffs them anyway.
    git difftool --no-prompt --no-index "$files_left" "$files_right" || true
  else
    git difftool --no-prompt --dir-diff "$diff_range" || true
  fi

  # The exit status is the difftool's, not a verdict — a tool that speaks no
  # contract cannot say whether the change is good, only that it closed.
  git_emit "absent"
}
