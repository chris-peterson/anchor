#!/usr/bin/env bash
# moor backend adapter for review-diff.sh (see SPEC.md "REV").
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_mode          "range" | "files"
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#
# moor's contract is a JSON sidecar named by MOOR_CONTEXT: the caller writes
# input.{title,details}, moor writes output.{exitCode,reviewer,comments,commitMessage}.
# This adapter drives git's configured difftool (moor when it's set as diff.tool),
# then maps that output onto the REV normalized result and prints:
#   REVIEW_VERDICT=<verdict>
#   REVIEW_OUTPUT=<normalized json>

# moor grades its comments, tracks per-hunk review, and round-trips an edited
# commit message; it does not mark diff sides or edit the CR description.
moor_caps='{"producesVerdict":true,"gradedSeverity":true,"perHunkReview":true,"editableCommitMessage":true,"editableDescription":false,"sideMarkers":false}'

# Consumes the review-request variables the dispatcher exports before sourcing
# this adapter (review_mode, diff_range, files_left/right, review_title,
# review_details_json); shellcheck can't follow that cross-file.
# shellcheck disable=SC2154
emit_review() {
  local cache_dir="$HOME/.cache/moor"
  mkdir -p "$cache_dir"
  local context_path="$cache_dir/context-$$.json"

  jq -n --arg t "$review_title" --argjson d "$review_details_json" \
    '{input:{title:$t, details:$d}}' > "$context_path"

  if [[ "$review_mode" == "files" ]]; then
    # Two arbitrary paths aren't a git range, so invoke moor directly. A non-zero
    # exit is the verdict, not a failure — the outcome lives in the sidecar.
    moor --context "$context_path" "$files_left" "$files_right" || true
  else
    export MOOR_CONTEXT="$context_path"
    git difftool --no-prompt --dir-diff "$diff_range" || true
  fi

  local output
  output=$(jq -c '.output // empty' "$context_path" 2>/dev/null || true)

  if [[ -z "$output" ]]; then
    # No sidecar output: a difftool that doesn't speak the contract showed the
    # diff (moor absent or not the configured tool), or moor closed without
    # writing one. Either way there is no contract verdict (REV-10).
    local out
    out=$(jq -cn '{
      backend:"difftool", verdict:"no-verdict", severitySource:"inferred",
      reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
      capabilities:{producesVerdict:false, gradedSeverity:false, perHunkReview:false,
        editableCommitMessage:false, editableDescription:false, sideMarkers:false},
      raw:{exitCode:"absent"}}')
    echo "REVIEW_VERDICT=no-verdict"
    echo "REVIEW_OUTPUT=$out"
    return
  fi

  local out
  out=$(jq -c --argjson caps "$moor_caps" '
    (.exitCode // "absent") as $ec
    | (if $ec==0 then "approved"
       elif $ec==1 then "changes-requested"
       elif $ec==2 then "incomplete"
       else "no-verdict" end) as $verdict
    | {
        backend:"moor",
        verdict:$verdict,
        severitySource:"graded",
        reviewCompleteness:(if $ec==0 or $ec==1 then "complete"
                            elif $ec==2 then "partial" else null end),
        reviewer:(.reviewer // null),
        comments:((.comments // []) | map({
          body:(.body // ""),
          action:(.action // "unspecified"),
          target:(if .target=="commit-message" then "changeset"
                  elif (.file and .startLine) then "line"
                  elif .file then "file" else "changeset" end),
          file:(.file // null),
          startLine:(.startLine // null),
          endLine:(.endLine // null),
          side:"new",
          raw:(.body // null)
        })),
        editedFields:(if .commitMessage
                      then [{target:"commit-message",
                             original:(.commitMessage.original // null),
                             edited:(.commitMessage.edited // null)}]
                      else [] end),
        capabilities:$caps,
        raw:{exitCode:$ec}
      }' <<<"$output")

  echo "REVIEW_VERDICT=$(jq -r '.verdict' <<<"$out")"
  echo "REVIEW_OUTPUT=$out"
}
