#!/usr/bin/env bash
# revdiff — a `diff` mode tool. Sourced by ../diff.sh once the mode and the
# tool are settled; it defines only what is revdiff's own, and the mode adapter
# owns the host, the header, and the normalized result. The contract these
# functions answer to is documented at the top of ../diff.sh.
#
# Two parts of the invocation are not obvious and are worth keeping written down:
#   * exit-code-on-annotations and no-tree go in as environment variables rather
#     than flags, because an old revdiff ignores an unknown env var and
#     hard-fails on an unknown flag.
#   * annotations come back through --output rather than stdout, since the pane's
#     stdout belongs to the terminal.
#   * a `--files` review runs in a scratch repo rather than revdiff's compare
#     mode, which refuses --only and --annotations, so it gets the context file
#     like any other.
#   * the verdict is a note on the context file's Verdict section
#     (lib/verdict.sh), since revdiff's own quits can't carry one: `q` with
#     nothing to say and `Q` discarding everything both exit 0 with no output.
#     `Q` is unbound for the review, so the one way out is `q`.
# revdiff's exit codes are 0 (clean quit), 10 (annotations captured), anything
# else a failure.

# revdiff annotates with diff-side markers but does not track per-hunk review or
# round-trip an edited commit message / description.
#
# These two are read by ../diff.sh, which sources this file; shellcheck lints a
# tool standalone (the dispatcher builds its path at run time) and so cannot
# see the consumer.
# shellcheck disable=SC2034
diff_tool_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":true,"preloadsAnnotations":true,"showsUntracked":true}'
diff_tool_install_hint='brew install umputun/apps/revdiff'

# The review's header also goes in the file tree, as a file at the root of the
# repo, so it sits beside what is under review rather than only behind `i`.
# revdiff reads a --only file that isn't in the diff straight from disk, so the
# file needs no --untracked, and the info/exclude entry keeps `git status` and
# `git add -A` from ever seeing it. A review that preloads notes (a batch, a
# review round) writes its own table there instead, which is shown the same way
# and read back as an item table rather than as feedback on the header.
REVDIFF_CONTEXT_FILE="(context).md"

# Set by diff_tool_before: the keys file the review runs with, and for a --files
# review, the scratch repo and the directory the review was asked from.
revdiff_keys=""
revdiff_scratch=""
# A --files review's draft, the copy of it revdiff shows (which `e` edits), and
# the review request the scratch repo rewrote, put back when it closes.
revdiff_draft="" revdiff_draft_copy="" revdiff_request=()
revdiff_home=""

# shellcheck source=../../lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/forge-url.sh"
# shellcheck source=../../lib/size-stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/size-stack.sh"
# shellcheck source=../../lib/callout.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/callout.sh"
# shellcheck source=../../lib/hints.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/hints.sh"
# shellcheck source=../../lib/verdict.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/verdict.sh"

# Read from the request variables the dispatcher exported.
# shellcheck disable=SC2154
revdiff_context_slot() {
  [[ "$review_subject" == "range" ]] || return 1
  local top
  top=$(git rev-parse --show-toplevel)
  ! git ls-files --error-unmatch -- "$top/$REVDIFF_CONTEXT_FILE" >/dev/null 2>&1 || return 1
  printf '%s' "$top/$REVDIFF_CONTEXT_FILE"
}

# The context file this adapter writes: every review but one whose caller
# preloads notes of its own and writes its own context file (a review round, a
# batch). A reply and the agent's notes on its changes ride with this header.
revdiff_context_path() {
  [[ -z "${review_annotations:-}" || -n "${review_reply:-}" || -n "${review_seeded:-}" ]] || return 1
  revdiff_context_slot
}

# The line of the context file the reply starts on, set by diff_tool_before; 0
# when the review carries none.
revdiff_reply_from=0

# One header detail, by label; empty when the review has none.
# shellcheck disable=SC2154
revdiff_detail() {
  jq -r --arg l "$1" '.[] | select(.label == $l) | .value | gsub("\n"; " ")' <<<"$review_details_json"
}

# git's shortstat (`N files changed, A insertions(+), D deletions(-)`, a count
# left out when it is zero) drawn as the one-row stack a reply review extends
# (lib/size-stack.sh), so the first review and the later ones read the same.
# <where> (the range, when there is one) goes on the line above it.
revdiff_size() {
  local stat="$1" where="$2" files added=0 removed=0
  [[ "$stat" =~ ^([0-9]+)\ files?\ changed ]] || { printf '%s%s\n' "$stat" "${where:+ $where}"; return; }
  files="${BASH_REMATCH[1]}"
  [[ "$stat" =~ ([0-9]+)\ insertions? ]] && added="${BASH_REMATCH[1]}"
  [[ "$stat" =~ ([0-9]+)\ deletions? ]] && removed="${BASH_REMATCH[1]}"
  [[ -z "$where" ]] || printf '%s\n' "$where"
  printf '\t%s\t%s\t%s\n' "$files" "$added" "$removed" | anchor_size_stack
}

# shellcheck disable=SC2154
diff_tool_before() {
  local repo repo_url top
  # Read where the review was asked from, before a --files review leaves it.
  repo=$(revdiff_detail repo)
  if [[ -z "$repo" ]] && top=$(git rev-parse --show-toplevel 2>/dev/null); then repo=$(basename "$top"); fi
  repo_url=$(anchor_repo_web_url)
  [[ "$review_subject" != files ]] || revdiff_files_scratch
  revdiff_header "$repo" "$repo_url"
  revdiff_unbind_discard
}

# The bindings this revdiff has (the user's own included), with every key for
# discard_quit unbound. Where they can't be read, `Q` stays bound, and quitting
# with it reads as no verdict chosen, which is asked about.
# shellcheck disable=SC2154
revdiff_unbind_discard() {
  local keys
  if ! keys=$("$review_tool" --dump-keys); then
    echo "$review_tool --dump-keys failed, so Q stays bound in this review" >&2
    return 0
  fi
  revdiff_keys=$(anchor_tmpfile anchor-revdiff-keys txt)
  # revdiff applies a file's unmaps before its maps, so the binding is left out
  # as well as unmapped: the unmap clears revdiff's default for that key.
  awk '$1 == "map" && $3 == "discard_quit" { unmap = unmap "unmap " $2 "\n"; next } { print }
       END { printf "%s", unmap }' <<<"$keys" > "$revdiff_keys"
}

revdiff_sgit() {
  git -C "$revdiff_scratch" -c user.name=anchor -c user.email=anchor@localhost \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# A --files review as a scratch repo: the left side committed as the base, the
# right side written over it and staged, so the review is the tree against
# HEAD, and the file goes by the reviewed object's reference where the caller
# named one, the right side's own name otherwise. The review then runs as a
# range review there, header included.
# shellcheck disable=SC2154
revdiff_files_scratch() {
  local name stat
  name=$(basename "$files_right")
  [[ -z "${files_name:-}" ]] || name="$files_name.${name##*.}"
  revdiff_scratch=$(anchor_tmpdir anchor-revdiff-files)
  git init --quiet "$revdiff_scratch"
  ! grep -q '[^[:space:]]' "$files_left" 2>/dev/null || cp "$files_left" "$revdiff_scratch/$name"
  revdiff_sgit add -A
  revdiff_sgit commit --quiet --allow-empty -m base
  cp "$files_right" "$revdiff_scratch/$name"
  revdiff_sgit add -- "$name"
  stat=$(revdiff_sgit diff --cached --shortstat HEAD | sed 's/^[[:space:]]*//')
  if [[ -z "$(revdiff_detail summary)" && -n "$stat" ]]; then
    review_details_json=$(jq -c --arg s "$stat" '. + [{label:"summary", value:$s}]' <<<"$review_details_json")
  fi
  revdiff_home=$PWD
  revdiff_draft="$files_right" revdiff_draft_copy="$revdiff_scratch/$name"
  revdiff_request=("$review_subject" "${diff_range:-}" "${diff_paths:-}")
  cd "$revdiff_scratch" || return 1
  review_subject=range diff_range=HEAD diff_paths="$name"
}

# What the reviewer changed in the draft's copy with revdiff's `e`, as
# editedFields, and that text written over the draft, so it is the draft the
# flow goes on with. revdiff reloads the copy after the edit, so the reviewer
# saw it.
diff_tool_edited() {
  local target
  if [[ -z "$revdiff_draft_copy" || ! -f "$revdiff_draft_copy" ]] || cmp -s "$revdiff_draft_copy" "$revdiff_draft"; then
    echo '[]'
    return
  fi
  target=$(anchor_artifact_target)
  jq -cn --arg t "${target:-description}" --rawfile o "$revdiff_draft" --rawfile e "$revdiff_draft_copy" \
    '[{target:$t, original:$o, edited:$e}]'
  cp "$revdiff_draft_copy" "$revdiff_draft"
}

# The editor a relaunch would open, by the name its command starts with; empty
# where the review carries no draft or no editor would open.
revdiff_relaunch_editor() {
  local ed
  [[ -n "$revdiff_draft" || -n "${message_file:-}" ]] || return 0
  anchor_editor_available || return 0
  ed=$(anchor_editor_resolve)
  [[ -n "$ed" ]] || return 0
  ed=${ed%% *}
  printf '%s' "${ed##*/}"
}

# The header as markdown, written for what revdiff colors in a .md file: the
# title as a heading, and the change's size under it, since how big a review is
# decides how to read it. Then the keys that work the review, in a box the reader
# who knows them skips, and the Verdict section, which says what each way of
# ending the review leads to. Then where the change sits, the repo and the base as links, and
# details anchor doesn't place (a caller's own --detail) as `label: value`. The
# details of the change come last: the body, set off by a blank line, then a
# reply's table and answers. revdiff shows the source, so no other line is spent
# on spacing. The popup copy stays plain text.
# shellcheck disable=SC2016,SC2154
revdiff_header() {
  local repo="$1" repo_url="$2" path exclude body where line label value next sha url
  path=$(revdiff_context_path) || return 0
  next=$(revdiff_detail next)
  exclude=$(git rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  grep -qxF -- "/$REVDIFF_CONTEXT_FILE" "$exclude" 2>/dev/null \
    || printf '/%s\n' "$REVDIFF_CONTEXT_FILE" >> "$exclude"
  body=$(jq -r '.[] | select(.label == "body") | .value' <<<"$review_details_json")
  {
    printf '# %s\n\n' "$review_title"
    value=$(revdiff_detail range)
    [[ -z "$value" ]] || value="in \`$value\`"
    if [[ -n "${review_reply:-}" && -s "$review_reply/sizes.tsv" ]]; then
      anchor_size_stack current < "$review_reply/sizes.tsv"
    elif [[ -n "$(revdiff_detail summary)" ]]; then
      revdiff_size "$(revdiff_detail summary)" "$value"
    elif [[ -n "$value" ]]; then
      printf '%s\n' "$value"
    fi
    anchor_revdiff_box "$review_tool" ""
    anchor_verdict_section "${next:-approve this review}" "stop, and nothing this review gates happens" "$(revdiff_relaunch_editor)"
    if [[ -n "$repo" ]]; then
      where="\`$repo\`"
      [[ -z "$repo_url" ]] || where="[$repo]($repo_url)"
      [[ -z "$(revdiff_detail branch)" ]] || where+=" on \`$(revdiff_detail branch)\`"
      printf '%s\n' "$where"
    fi
    value=$(revdiff_detail "on top of")
    if [[ -n "$value" ]]; then
      sha="${value%% *}" url=""
      # A base only this checkout holds has no page to link to.
      [[ -z "$(git branch -r --contains "$sha" 2>/dev/null | head -1)" ]] || url=$(anchor_commit_web_url "$sha")
      if [[ -n "$url" ]]; then printf 'base [%s](%s)\n' "$sha" "$url"; else printf 'base `%s`\n' "$sha"; fi
    fi
    value=$(revdiff_detail commit)
    if [[ -n "$value" ]]; then
      line="commit \`$value\`"
      [[ -z "$(revdiff_detail author)" ]] || line+=" by $(revdiff_detail author | sed 's/ <[^>]*>$//')"
      printf '%s\n' "$line"
    fi
    value=$(revdiff_detail base)
    [[ -z "$value" ]] || printf 'against `%s`, %s commit%s\n' "$value" "$(revdiff_detail commits)" \
      "$([[ "$(revdiff_detail commits)" == 1 ]] || echo s)"
    while IFS=$'\x1f' read -r label value; do
      [[ -n "$label" ]] && printf '%s: %s\n' "$label" "$value"
    done < <(jq -r '.[] | select(.label | IN("body","repo","branch","on top of","commit","author","base","commits","summary","range","next","opened by") | not)
      | "\(.label)\u001f\(.value | gsub("\n"; " "))"' <<<"$review_details_json")
    [[ -z "$body" ]] || printf '\n%s\n' "$body"
  } > "$path"
  if [[ -n "${review_reply:-}" ]]; then
    revdiff_reply_from=$(awk 'END { print NR + 1 }' "$path")
    cat "$review_reply/reply.md" >> "$path"
  fi
}

diff_tool_cleanup() {
  local path
  [[ -z "$revdiff_keys" ]] || rm -f "$revdiff_keys"
  if [[ -n "$revdiff_scratch" ]]; then
    cd "$revdiff_home" || return 1
    rm -rf "$revdiff_scratch"
    review_subject=${revdiff_request[0]} diff_range=${revdiff_request[1]} diff_paths=${revdiff_request[2]}
    return 0
  fi
  path=$(revdiff_context_path) || return 0
  rm -f "$path"
}

# The `sh` command string that runs one review. The refs come from the request
# variables the dispatcher exported; the flags are revdiff's own.
# shellcheck disable=SC2154
diff_tool_command() {
  local bin="$1" out_file="$2" err_file="$3" desc_file="$4"
  local cmd arg
  local -a args=("--description-file=$desc_file")
  # Both are flags rather than REVDIFF_CONFIG entries: revdiff reads
  # --annotations from the command line only.
  [[ -z "${review_annotations:-}" ]] || args+=("--annotations=$review_annotations")
  [[ "${review_untracked:-0}" -ne 1 ]] || args+=(--untracked)

  if [[ "$diff_staged" -eq 1 ]]; then
    args+=(--staged)
  else
    case "$diff_range" in
      *...*) args+=("${diff_range%%...*}" "${diff_range##*...}") ;;
      *..*)  args+=("${diff_range%%..*}" "${diff_range##*..}") ;;
      *)     args+=("$diff_range") ;;
    esac
  fi
  # A directory is a prefix to include; a file is shown exactly, since a prefix
  # would also take `a.txt.bak` along with `a.txt`.
  local p top paths="${diff_paths:-}" context=0 shown=0
  top=$(git rev-parse --show-toplevel)
  # --only narrows the tree to what it names, so the context file comes with
  # every changed path, both names of a rename among them.
  if [[ -f "$top/$REVDIFF_CONTEXT_FILE" ]] && revdiff_context_slot >/dev/null; then
    # A reply shows the named paths that changed since the last review, and the
    # files its notes answer in, changed or not.
    if [[ -n "${review_reply:-}" ]]; then
      local -a specs=()
      while IFS= read -r p; do specs+=("$p"); done < <(anchor_diff_specs)
      paths=$(git -c core.quotePath=false diff --name-only --no-renames "$diff_range" -- "${specs[@]+"${specs[@]}"}")
      paths+=$'\n'$(jq -r '[.[].file] | unique[]' "$review_reply/notes.json")
      paths=$(awk 'NF && !seen[$0]++' <<<"$paths")
    elif [[ -z "$paths" ]]; then
      if [[ "$diff_staged" -eq 1 ]]; then
        paths=$(git -c core.quotePath=false diff --cached --name-only --no-renames "$diff_range")
      else
        paths=$(git -c core.quotePath=false diff --name-only --no-renames "$diff_range")
      fi
      if [[ "${review_untracked:-0}" -eq 1 ]]; then
        paths+=$'\n'$(git -c core.quotePath=false ls-files --others --exclude-standard)
      fi
    fi
    args+=("--only=$REVDIFF_CONTEXT_FILE")
    context=1
  fi
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    shown=$((shown + 1))
    if [[ -d "$top/$p" ]]; then args+=("--include=${p%/}/"); else args+=("--only=$p"); fi
  done <<< "$paths"

  cmd="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true"
  # A lone unchanged markdown file turns revdiff's tree into an outline of its
  # headings, which reads as a list of files. A reply with nothing changed and
  # every answer in the context file is that case.
  [[ "$context" -eq 0 || "$shown" -gt 0 ]] || cmd+=" REVDIFF_NO_TREE=true"
  cmd="$cmd $(anchor_host_sq "$bin")"
  cmd="$cmd $(anchor_host_sq "--output=$out_file")"
  if [[ -n "${REVDIFF_CONFIG:-}" && -f "${REVDIFF_CONFIG}" ]]; then
    cmd="$cmd $(anchor_host_sq "--config=$REVDIFF_CONFIG")"
  fi
  [[ -z "$revdiff_keys" ]] || cmd="$cmd $(anchor_host_sq "--keys=$revdiff_keys")"
  for arg in "${args[@]}"; do cmd="$cmd $(anchor_host_sq "$arg")"; done
  # The pane closes the moment a fast-failing revdiff exits, taking the error
  # text with it, so stderr is captured rather than drawn.
  cmd="$cmd 2>$(anchor_host_sq "$err_file")"
  printf '%s' "$cmd"
}

# Parse revdiff's markdown annotations into the DIFF comments array. Each block is
#   ## <file> (file-level)  | ## <file>:<line> (+|-| )  | ## <file>:<a>-<b> (+|-| )
# where ( ) is an unchanged line, numbered on the new side as (+) is.
# followed by a possibly multi-line body. revdiff space-prefixes any body line
# that begins with "## " so it never looks like a header.
#
# A note on the context file this adapter wrote is the reviewer writing on the
# header, so it comes back aimed at the commit message where the review carries
# one, and at the changeset otherwise; an edited message never reads as approved.
# A note on a reply's part of that file answers the reply, so it is aimed at the
# changeset. Either keeps its line and quotes it: the file is gone once the
# review closes, and a note on the keys or the size isn't about the message.
# A note on one of the Verdict section's lines, whoever wrote the file, is the
# reviewer's choice: target `verdict`, with `choice` naming the line.
diff_tool_comments() {
  local out_file="$1"
  [[ -s "$out_file" ]] || { echo '[]'; return; }
  local target=changeset ctx="" ctx_path ctx_text="" vlines
  [[ -z "${message_file:-}" ]] || target=commit-message
  if ctx_path=$(revdiff_context_path); then
    ctx=$REVDIFF_CONTEXT_FILE
    [[ ! -f "$ctx_path" ]] || ctx_text=$(cat "$ctx_path")
  fi
  vlines=$(anchor_verdict_lines "$(git rev-parse --show-toplevel)/$REVDIFF_CONTEXT_FILE" \
    | jq -Rn '[inputs | split("\t") | {key:.[1], value:.[0]}] | from_entries')
  jq -Rs --arg ctx "$ctx" --arg ctxtext "$ctx_text" --arg mtarget "$target" --argjson reply "$revdiff_reply_from" \
    --arg cfile "$REVDIFF_CONTEXT_FILE" --argjson vlines "$vlines" '
    def parse_header:
      if test("\\(file-level\\)$") then
        capture("^(?<file>.+) \\(file-level\\)$") + {target:"file", side:"new"}
      elif test(":[0-9]+-[0-9]+ \\([-+ ]\\)$") then
        capture("^(?<file>.+):(?<s>[0-9]+)-(?<e>[0-9]+) \\((?<sd>[-+ ])\\)$")
        | {file, target:"line", startLine:(.s|tonumber), endLine:(.e|tonumber),
           side:(if .sd=="-" then "old" else "new" end)}
      elif test(":[0-9]+ \\([-+ ]\\)$") then
        capture("^(?<file>.+):(?<s>[0-9]+) \\((?<sd>[-+ ])\\)$")
        | {file, target:"line", startLine:(.s|tonumber), endLine:(.s|tonumber),
           side:(if .sd=="-" then "old" else "new" end)}
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
    | [.[]
        | ($vlines[(.startLine // 0) | tostring] // null) as $choice
        | if .file == $cfile and .target == "line" and $choice != null then
            .file = null | .target = "verdict" | .choice = $choice
          elif $ctx == "" or .file != $ctx then .
          else (if $reply > 0 and (.startLine // 0) >= $reply then "changeset" else $mtarget end) as $t
            | .file = null | .target = $t
            | if .startLine then . as $c
                | .quote = ($ctxtext | split("\n") | .[$c.startLine - 1 : $c.endLine] | join("\n"))
              else . end
          end]
  ' "$out_file"
}

# The context file outside its table's rows: a note on a row answers that row.
diff_tool_shared_note() {
  local file line
  file=$(jq -r '.file // ""' <<<"$1")
  line=$(jq -r '.startLine // 0' <<<"$1")
  [[ "$file" == "$REVDIFF_CONTEXT_FILE" ]] || return 1
  [[ "$line" -gt 0 ]] || return 0
  ! sed -n "${line}p" "$(git rev-parse --show-toplevel)/$REVDIFF_CONTEXT_FILE" | grep -q '^|'
}

# The choice on the Verdict section decides; with none, notes of the reviewer's
# ask for a revision, and a review with neither (or both choices) is undecided.
diff_tool_verdict() {
  local rc="$1" comments="$2" chosen
  [[ "$rc" -eq 0 || "$rc" -eq 10 ]] || { printf 'no-verdict'; return; }   # 1 (error) or anything unexpected
  chosen=$(jq -r '[.[] | select(.target == "verdict") | .choice] | unique | join(",")' <<<"$comments")
  case "$chosen" in
    accept)   printf 'approved' ;;
    reject)   printf 'rejected' ;;
    relaunch) printf 'relaunch' ;;
    "")     if [[ "$(jq 'length' <<<"$comments")" -gt 0 ]]; then
              printf 'changes-requested'
            else
              printf 'undecided'
            fi ;;
    *)      printf 'undecided' ;;
  esac
}
