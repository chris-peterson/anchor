#!/usr/bin/env bash
# revdiff — a `diff` mode tool. Sourced by ../diff.sh once the mode and the
# tool are settled; it defines only what is revdiff's own, and the mode adapter
# owns the host, the header, and the normalized result. The contract these
# functions answer to is documented at the top of ../diff.sh.
#
# Two parts of the invocation are not obvious and are worth keeping written down:
#   * exit-code-on-annotations goes in as an environment variable rather than a
#     flag, because an old revdiff ignores an unknown env var and hard-fails on
#     an unknown flag.
#   * annotations come back through --output rather than stdout, since the pane's
#     stdout belongs to the terminal.
# revdiff's exit codes are 0 (clean quit), 10 (annotations captured), anything
# else a failure.

# revdiff annotates with diff-side markers but does not track per-hunk review or
# round-trip an edited commit message / description.
#
# These two are read by ../diff.sh, which sources this file; shellcheck lints a
# tool standalone (the dispatcher builds its path at run time) and so cannot
# see the consumer.
# shellcheck disable=SC2034
diff_tool_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":true}'
diff_tool_install_hint='brew install umputun/apps/revdiff'
diff_tool_reviews_index=1

# The `sh` command string that runs one review. The refs come from the request
# variables the dispatcher exported; the flags are revdiff's own.
# shellcheck disable=SC2154
diff_tool_command() {
  local bin="$1" out_file="$2" err_file="$3" desc_file="$4"
  local cmd arg
  local -a args=("--description-file=$desc_file")

  if [[ "$review_subject" == "files" ]]; then
    args+=("--compare-old=$files_left" "--compare-new=$files_right")
  elif [[ "$diff_staged" -eq 1 ]]; then
    args+=(--staged)
  else
    case "$diff_range" in
      *...*) args+=("${diff_range%%...*}" "${diff_range##*...}") ;;
      *..*)  args+=("${diff_range%%..*}" "${diff_range##*..}") ;;
      *)     args+=("$diff_range") ;;
    esac
  fi

  cmd="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true $(anchor_host_sq "$bin")"
  cmd="$cmd $(anchor_host_sq "--output=$out_file")"
  if [[ -n "${REVDIFF_CONFIG:-}" && -f "${REVDIFF_CONFIG}" ]]; then
    cmd="$cmd $(anchor_host_sq "--config=$REVDIFF_CONFIG")"
  fi
  for arg in "${args[@]}"; do cmd="$cmd $(anchor_host_sq "$arg")"; done
  # The pane closes the moment a fast-failing revdiff exits, taking the error
  # text with it, so stderr is captured rather than drawn.
  cmd="$cmd 2>$(anchor_host_sq "$err_file")"
  printf '%s' "$cmd"
}

# Parse revdiff's markdown annotations into the DIFF comments array. Each block is
#   ## <file> (file-level)         | ## <file>:<line> (+|-)  | ## <file>:<a>-<b> (+|-)
# followed by a possibly multi-line body. revdiff space-prefixes any body line
# that begins with "## " so it never looks like a header.
#
# The fork echoes the seeded --description back as a `(description)` block on
# quit. An echo that matches the seeded header (<desc_file>) says nothing and is
# dropped; one that differs is the reviewer writing on the message, and comes
# back as a comment targeting it, so an edited message never reads as approved.
# TODO: route a changed `(description)` to editedFields once the round-trip lands.
diff_tool_comments() {
  local out_file="$1" desc_file="${2:-}"
  [[ -s "$out_file" ]] || { echo '[]'; return; }
  local seed="" target=description
  [[ -n "$desc_file" && -f "$desc_file" ]] && seed=$(cat "$desc_file")
  [[ -z "${message_file:-}" ]] || target=commit-message
  jq -Rs --arg seed "$seed" --arg mtarget "$target" '
    def norm: split("\n") | map(sub("^\\s+";"") | sub("\\s+$";""))
      | map(select(length > 0)) | join("\n");
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
    | ($seed | norm) as $s
    | [.[]
        | if .file != "(description)" then .
          elif (.body | norm) == $s then empty
          else .file = null | .target = $mtarget | .startLine = null | .endLine = null
          end]
  ' "$out_file"
}

diff_tool_verdict() {
  local rc="$1" comments="$2"
  case "$rc" in
    0)  printf 'approved' ;;
    10) if [[ "$(jq 'length' <<<"$comments")" -gt 0 ]]; then
          printf 'changes-requested'
        else
          # Exit 10 was only the echoed description, with no real feedback.
          printf 'approved'
        fi ;;
    *)  printf 'no-verdict' ;;   # 1 (error) or anything unexpected
  esac
}
