#!/usr/bin/env bash
# The DIFF-10 result: a difftool put the change on screen and graded nothing.
#
# Sourced, not executed. Two adapters land on this shape and it has to be the
# same object from both:
#
#   scripts/review/git.sh   the tool git resolves speaks no contract, so this is
#                           the only result it can produce
#   scripts/review/moor.sh  the sidecar came back empty — moor is absent, or is
#                           not git's configured diff.tool, so what ran was a
#                           plain difftool
#
# Consumers branch on `backend: "difftool"` to take the fallback ladder
# (guides/review-fallback.md) rather than to ask whether the shown diff is
# approved. A second hand-written copy that drifted would strand one adapter's
# callers on a rung they were never offered.

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
