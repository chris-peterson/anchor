#!/usr/bin/env bash
# revdiff backend adapter for review-diff.sh (see SPEC.md "DIFF").
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_mode          "range" | "files"
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#
# revdiff is a terminal TUI, so it needs a terminal to render, and anchor
# launches review from a background Bash call with no controlling TTY. The
# terminal is a split of the calling iTerm2 session, opened by
# scripts/lib/split-run.sh — the same runner the editor backend uses.
#
# anchor drives the revdiff binary itself. Two parts of that invocation are not
# obvious and are worth keeping written down:
#   * exit-code-on-annotations goes in as an environment variable rather than a
#     flag, because an old revdiff ignores an unknown env var and hard-fails on
#     an unknown flag.
#   * annotations come back through --output rather than stdout, since the pane's
#     stdout belongs to the terminal.
# revdiff's exit codes are 0 (clean quit), 10 (annotations captured), anything
# else a failure. Its warnings go to stderr on a successful review too, so stderr
# is replayed only when the run actually failed.

# revdiff carries no per-hunk review state and no commit-message round-trip
# anchor consumes yet, so those dimensions are null/off; on the revdiff backend
# the caller confirms the commit message itself. (The fork's editable
# `(description)` output isn't parsed here yet — see the DIFF plan.)

# shellcheck source=../lib/split-run.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/split-run.sh"

# revdiff annotates with diff-side markers but does not track per-hunk review or
# round-trip an edited commit message / description.
revdiff_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":true}'

# Parse revdiff's markdown annotations into the DIFF comments array. Each block is
#   ## <file> (file-level)         | ## <file>:<line> (+|-)  | ## <file>:<a>-<b> (+|-)
# followed by a possibly multi-line body. revdiff space-prefixes any body line
# that begins with "## " so it never looks like a header.
revdiff_parse_comments() {
  local out_file="$1"
  [[ -s "$out_file" ]] || { echo '[]'; return; }
  jq -Rs '
    def parse_header:
      if test("\\(file-level\\)$") then
        capture("^(?<file>.+) \\(file-level\\)$") + {target:"file", side:"new"}
      elif test(":[0-9]+-[0-9]+ \\([-+]\\)$") then
        capture("^(?<file>.+):(?<s>[0-9]+)-(?<e>[0-9]+) \\((?<sd>[-+])\\)$")
        | {file, target:"line", startLine:(.s|tonumber), endLine:(.e|tonumber),
           side:(if .sd=="+" then "new" else "old" end)}
      elif test(":[0-9]+ \\([-+]\\)$") then
        capture("^(?<file>.+):(?<s>[0-9]+) \\((?<sd>[-+])\\)$")
        | {file, target:"line", startLine:(.s|tonumber), endLine:(.s|tonumber),
           side:(if .sd=="+" then "new" else "old" end)}
      else
        {file:null, target:"changeset", side:"new"}
      end;
    ("\n" + .)
    | split("\n## ")
    | map(select(test("\\S")))
    | map(
        (split("\n")) as $l
        | ($l[0] | parse_header) as $h
        | ($l[1:] | join("\n") | sub("^\\s+";"") | sub("\\s+$";"")) as $body
        | {
            body:$body,
            target:$h.target,
            file:($h.file // null),
            startLine:($h.startLine // null),
            endLine:($h.endLine // null),
            side:$h.side,
            raw:$body
          }
      )
  ' "$out_file"
}

# Consumes the review-request variables the dispatcher exports before sourcing
# this adapter (review_mode, diff_range, files_left/right, review_title,
# review_details_json); shellcheck can't follow that cross-file.
# shellcheck disable=SC2154
emit_review() {
  revdiff_unavailable() {
    echo "review-diff.sh: $1" >&2
    jq -cn --argjson caps "$revdiff_caps" --arg rc "$2" '{
      backend:"revdiff", verdict:"no-verdict",
      reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
      capabilities:($caps + {producesVerdict:false}), raw:{exitCode:$rc}}' \
      | { read -r out; echo "REVIEW_VERDICT=no-verdict"; echo "REVIEW_OUTPUT=$out"; }
  }

  local revdiff_bin
  revdiff_bin=$(command -v revdiff 2>/dev/null || true)
  if [[ -z "$revdiff_bin" ]]; then
    revdiff_unavailable "revdiff is not installed (brew install umputun/apps/revdiff)" absent
    return
  fi
  if ! anchor_split_available; then
    revdiff_unavailable "revdiff needs a terminal to render, and this session has nowhere to open one — it opens in a split of the calling iTerm2 session" no-host
    return
  fi

  local desc_file
  desc_file=$(mktemp "${TMPDIR:-/tmp}/revdiff-desc.XXXXXX")
  {
    printf '# %s\n\n' "$review_title"
    jq -r '.[] | "- **\(.label):** \(.value)"' <<<"$review_details_json"
  } > "$desc_file"

  # The refs and the seeded header; the invocation's own flags are added below.
  local -a args=("--description-file=$desc_file")
  if [[ "$review_mode" == "files" ]]; then
    args+=("--compare-old=$files_left" "--compare-new=$files_right")
  else
    case "$diff_range" in
      *...*) args+=("${diff_range%%...*}" "${diff_range##*...}") ;;
      *..*)  args+=("${diff_range%%..*}" "${diff_range##*..}") ;;
      *)     args+=("$diff_range") ;;
    esac
  fi

  local out_file err_file
  out_file=$(mktemp "${TMPDIR:-/tmp}/revdiff-out.XXXXXX")
  err_file=$(mktemp "${TMPDIR:-/tmp}/revdiff-err.XXXXXX")

  local cmd arg
  cmd="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true $(anchor_split_sq "$revdiff_bin")"
  cmd="$cmd $(anchor_split_sq "--output=$out_file")"
  if [[ -n "${REVDIFF_CONFIG:-}" && -f "${REVDIFF_CONFIG}" ]]; then
    cmd="$cmd $(anchor_split_sq "--config=$REVDIFF_CONFIG")"
  fi
  for arg in "${args[@]}"; do cmd="$cmd $(anchor_split_sq "$arg")"; done
  # The pane closes the moment a fast-failing revdiff exits, taking the error
  # text with it, so stderr is captured rather than drawn.
  cmd="$cmd 2>$(anchor_split_sq "$err_file")"

  local rc=0
  anchor_split_run "$cmd" || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 10 && -s "$err_file" ]]; then
    cat "$err_file" >&2
  fi

  # The fork echoes the seeded --description back as a `(description)` block on
  # quit (and would carry an edited message there). The description round-trip
  # isn't consumed yet (see the DIFF plan), so drop those blocks and derive the
  # verdict from real code comments only — otherwise a seeded message would
  # always read as changes-requested. TODO: when the round-trip lands, route a
  # changed `(description)` to editedFields[commit-message] instead of dropping.
  local comments
  comments=$(revdiff_parse_comments "$out_file" | jq -c '[.[] | select(.file != "(description)")]')

  local verdict
  case "$rc" in
    0)  verdict="approved" ;;
    10) if [[ "$(jq 'length' <<<"$comments")" -gt 0 ]]; then
          verdict="changes-requested"
        else
          verdict="approved"   # exit 10 was only the echoed description, no real feedback
        fi ;;
    *)  verdict="no-verdict" ;;   # 1 (error) or anything unexpected
  esac

  local out
  out=$(jq -cn \
    --arg v "$verdict" \
    --argjson caps "$revdiff_caps" \
    --argjson comments "$comments" \
    --argjson rc "$rc" '
    {
      backend:"revdiff",
      verdict:$v,
      reviewCompleteness:null,
      reviewer:null,
      comments:$comments,
      editedFields:[],
      capabilities:$caps,
      raw:{exitCode:$rc}
    }')

  rm -f "$out_file" "$err_file" "$desc_file"
  echo "REVIEW_VERDICT=$verdict"
  echo "REVIEW_OUTPUT=$out"
}
