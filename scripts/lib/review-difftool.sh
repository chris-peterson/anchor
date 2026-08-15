#!/usr/bin/env bash
# The DIFF-10 result: a difftool put the change on screen and graded nothing.
#
# Sourced, not executed. Reached from `scripts/review/moor.sh` when the sidecar
# comes back empty: that adapter drives `git difftool` to get to moor, so a moor
# that is absent, or that is not git's configured `diff.tool`, leaves a plain
# difftool on screen and nothing to map.
#
# No backend selects this — DIFF-18 keeps the difftool off the menu, so it is
# only ever a report of what happened. It lives in a lib rather than inline in
# moor's adapter because the shape is the contract's (DIFF-10), not moor's, and
# the next adapter to reach the same dead end has to emit the identical object:
# consumers branch on `backend: "difftool"` to take the fallback ladder
# (guides/review-fallback.md) rather than to ask whether the shown diff is
# approved.

anchor_difftool_caps='{"producesVerdict":false,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":false}'

# `raw.exitCode` is `absent` rather than the difftool's status: a tool that
# speaks no contract can report only that it closed, and reporting a 0 there
# would read as a verdict it never gave.
anchor_difftool_emit() {
  local out
  out=$(jq -cn --argjson caps "$anchor_difftool_caps" '{
    backend:"difftool", verdict:"no-verdict",
    reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
    capabilities:$caps, raw:{exitCode:"absent"}}')
  echo "REVIEW_VERDICT=no-verdict"
  echo "REVIEW_OUTPUT=$out"
}
