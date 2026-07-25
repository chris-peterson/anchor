#!/usr/bin/env bash
# revdiff backend adapter for review-diff.sh (see SPEC.md "REV").
#
# Sourced by the dispatcher, which has already cd'd into the target repo and
# resolved the review request into these variables:
#   review_mode          "range" | "files"
#   diff_range           the git range (range mode)
#   files_left/right     the two paths (files mode)
#   review_title         the header title
#   review_details_json  the header details, a JSON array of {label,value}
#
# revdiff is a terminal TUI, so — unlike moor's GUI window — it needs a terminal
# to render, and anchor launches review from a background Bash call with no
# controlling TTY. Launching `revdiff` directly there fails ("could not open a
# new TTY"). So this adapter delegates terminal launching to the revdiff plugin's
# launch-revdiff.sh, which opens revdiff in a terminal overlay (tmux/zellij/
# kitty/iTerm2/…), captures the annotations to stdout, and exits with revdiff's
# code (0 none / 10 annotations / other failure). anchor keeps range resolution
# and normalization; the launcher owns the terminal.
#
# The launcher is discovered in the revdiff plugin's cache, which couples anchor
# to that plugin's internal file layout. TODO: consider filing a revdiff issue
# for a stable launch entrypoint (e.g. a `revdiff` overlay mode, or a plugin-
# exposed launcher path) so this can call a supported interface instead — set
# ANCHOR_REVDIFF_LAUNCHER to override discovery in the meantime.
#
# revdiff carries no severity, no per-hunk review state, and no commit-message
# round-trip anchor consumes yet, so those dimensions are inferred/null/off; on
# the revdiff backend the caller confirms the commit message itself. (The fork's
# editable `(description)` output isn't parsed here yet — see the REV plan.)

# revdiff annotates with diff-side markers but does not grade, track per-hunk
# review, or round-trip an edited commit message / description.
revdiff_caps='{"producesVerdict":true,"gradedSeverity":false,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":true}'

# Resolve the terminal-overlay launcher: an explicit override (also the seam
# tests use), else the newest launch-revdiff.sh in the revdiff plugin's cache.
revdiff_launcher() {
  if [[ -n "${ANCHOR_REVDIFF_LAUNCHER:-}" ]]; then
    printf '%s\n' "$ANCHOR_REVDIFF_LAUNCHER"
    return
  fi
  local reset
  reset=$(shopt -p nullglob)
  shopt -s nullglob
  local -a matches=(
    "$HOME"/.claude/plugins/cache/*/revdiff/*/.claude-plugin/skills/revdiff/scripts/launch-revdiff.sh
  )
  eval "$reset"
  [[ ${#matches[@]} -gt 0 ]] || return 0
  printf '%s\n' "${matches[@]}" | sort -V | tail -1
}

# Parse revdiff's markdown annotations into the REV comments array. Each block is
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
            action:"unspecified",
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
  local launcher
  launcher=$(revdiff_launcher)
  if [[ -z "$launcher" || ! -x "$launcher" ]]; then
    echo "review-diff.sh: revdiff launcher not found (install the revdiff plugin, or set ANCHOR_REVDIFF_LAUNCHER)" >&2
    jq -cn --argjson caps "$revdiff_caps" '{
      backend:"revdiff", verdict:"no-verdict", severitySource:"inferred",
      reviewCompleteness:null, reviewer:null, comments:[], editedFields:[],
      capabilities:($caps + {producesVerdict:false}), raw:{exitCode:"absent"}}' \
      | { read -r out; echo "REVIEW_VERDICT=no-verdict"; echo "REVIEW_OUTPUT=$out"; }
    return
  fi

  local desc_file
  desc_file=$(mktemp "${TMPDIR:-/tmp}/revdiff-desc.XXXXXX")
  {
    printf '# %s\n\n' "$review_title"
    jq -r '.[] | "- **\(.label):** \(.value)"' <<<"$review_details_json"
  } > "$desc_file"

  # The launcher adds --output and REVDIFF_EXIT_CODE_ON_ANNOTATIONS itself and
  # returns the annotations on stdout, so pass only the refs and the header.
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

  local annotations rc=0
  annotations=$("$launcher" "${args[@]}") || rc=$?

  local out_file
  out_file=$(mktemp "${TMPDIR:-/tmp}/revdiff-out.XXXXXX")
  printf '%s' "$annotations" > "$out_file"

  # The fork echoes the seeded --description back as a `(description)` block on
  # quit (and would carry an edited message there). The description round-trip
  # isn't consumed yet (see the REV plan), so drop those blocks and derive the
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
      severitySource:"inferred",
      reviewCompleteness:null,
      reviewer:null,
      comments:$comments,
      editedFields:[],
      capabilities:$caps,
      raw:{exitCode:$rc}
    }')

  rm -f "$out_file" "$desc_file"
  echo "REVIEW_VERDICT=$verdict"
  echo "REVIEW_OUTPUT=$out"
}
