#!/usr/bin/env bash
# Render a review's findings into the exact text that will reach the change
# request, and — on a separate invocation — post it. Both halves build the
# bodies from the same findings file through the same code, so what the user
# approved in the preview is byte-for-byte what lands (CONFIRM-01..02).
#
# The findings file is JSON, and its `comments` entries use the DIFF contract's
# comment shape (SPEC.md "DIFF") so a comment the reviewer typed in the diff
# viewer and one the skill wrote are the same kind of object:
#
#   {
#     "cr":       {"url": "…", "headSha": "…"},
#     "summary":  "markdown prose — the overall read",
#     "comments": [
#       {"body": "…", "target": "line", "file": "src/x.js",
#        "startLine": 42, "endLine": 42, "side": "new", "origin": "reviewer"}
#     ]
#   }
#
# `target: "line"` with a file and a start line is anchorable and posts as an
# inline thread. Everything else — a `file` or `changeset` target, or a line
# target the forge rejects — folds into the summary comment rather than being
# dropped. GitHub could carry a file-level comment natively (`subject_type:
# file`) and GitLab lists `position_type: file` without specifying it, so
# anchoring only lines keeps the two forges saying the same thing.
#
# Head-SHA guard: `cr.headSha` was pinned by review-cr.sh when the diff was
# fetched. A CR whose author pushes mid-review moves the lines out from under
# every anchor, so this re-reads the head before posting and refuses on a
# mismatch instead of landing comments on a diff nobody reviewed.
#
# Usage:
#   review-post.sh --preview  --findings <path> --forge <f> --project <p> --cr <n>
#   review-post.sh --post     --findings <path> --forge <f> --project <p> --cr <n> \
#                             [--host <h>] [--base-sha <s>] [--start-sha <s>] \
#                             [--index <n|summary>]
#
# --index posts one finding (1-based, as numbered by --preview) or the summary
# alone; without it everything posts. On GitHub the everything case is a single
# batched review (`event: COMMENT`) so the author gets one notification rather
# than N; GitLab has no batch endpoint, so each thread is its own POST.
#
# Output (KEY=value on stdout):
#   POSTED_INLINE=<n>     inline threads that landed
#   POSTED_SUMMARY=<0|1>  whether the summary comment landed
#   POST_ERROR=<message>  on refusal or failure (with a non-zero exit)

set -euo pipefail

# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

mode=""
findings=""
forge=""
project=""
cr_iid=""
host=""
base_sha=""
start_sha=""
index=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview)    mode=preview; shift ;;
    --post)       mode=post; shift ;;
    --findings)   findings="${2:?--findings needs a path}"; shift 2 ;;
    --forge)      forge="${2:?--forge needs github|gitlab}"; shift 2 ;;
    --project)    project="${2:?--project needs a path}"; shift 2 ;;
    --cr)         cr_iid="${2:?--cr needs a number}"; shift 2 ;;
    --host)       host="${2:?--host needs a hostname}"; shift 2 ;;
    --base-sha)   base_sha="${2:?--base-sha needs a sha}"; shift 2 ;;
    --start-sha)  start_sha="${2:?--start-sha needs a sha}"; shift 2 ;;
    --index)      index="${2:?--index needs a number or 'summary'}"; shift 2 ;;
    *) echo "review-post.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$mode" ]] || { echo "review-post.sh: one of --preview / --post is required" >&2; exit 64; }
[[ -r "$findings" ]] || { echo "review-post.sh: cannot read findings file: $findings" >&2; exit 66; }

fail() { echo "POST_ERROR=$*"; exit 65; }

jq -e . "$findings" >/dev/null 2>&1 || fail "findings file is not valid JSON: $findings"

# --- Split the findings into anchored and unanchored --------------------------

anchorable='.target == "line" and (.file // "") != "" and (.startLine // 0) > 0'
anchored=$(jq -c "[.comments[] | select($anchorable)]" "$findings")
loose=$(jq -c "[.comments[] | select($anchorable | not)]" "$findings")
anchored_count=$(jq 'length' <<<"$anchored")

# The summary body is the prose plus every finding that could not be anchored,
# each named with its file so the author can still find what it is about.
build_summary() {
  jq -r --argjson loose "$loose" '
    (.summary // "") as $prose
    | ($loose | map(
        "- " + (if (.file // "") != "" then "**" + .file + "** — " else "" end) + .body
      ) | join("\n")) as $rest
    | if $rest == "" then $prose
      else ($prose | if . == "" then "" else . + "\n\n" end)
           + "**Not anchored to a line:**\n\n" + $rest
      end
  ' "$findings"
}

# --- Preview ------------------------------------------------------------------

if [[ "$mode" == preview ]]; then
  echo "## Inline threads ($anchored_count)"
  echo
  if [[ "$anchored_count" -eq 0 ]]; then
    echo "_none_"
    echo
  else
    jq -r 'to_entries[] | "### \(.key + 1). \(.value.file):\(.value.startLine)\(if (.value.endLine // .value.startLine) != .value.startLine then "-" + ((.value.endLine)|tostring) else "" end) (\(.value.side // "new"))\n\n\(.value.body)\n"' <<<"$anchored"
  fi
  summary=$(build_summary)
  echo "## Summary comment"
  echo
  if [[ -z "$summary" ]]; then echo "_none_"; else printf '%s\n' "$summary"; fi
  exit 0
fi

# --- Post ---------------------------------------------------------------------

[[ -n "$forge" && -n "$project" && -n "$cr_iid" ]] \
  || { echo "review-post.sh: --post needs --forge, --project, and --cr" >&2; exit 64; }

pinned=$(jq -r '.cr.headSha // ""' "$findings")
[[ -n "$pinned" ]] || fail "findings file carries no cr.headSha — re-run review-cr.sh rather than posting against an unpinned diff"

# GitLab's `glab api` expands :fullpath from the current git dir, which is the
# wrong project whenever the CR isn't the cwd repo's — substitute the encoded
# path instead. See guides/forge-cookbook.md, "Targeting a repo that isn't the
# working directory".
gl_project=$(jq -rn --arg p "$project" '$p | @uri')
gl_api() {
  local args=(api)
  [[ -n "$host" ]] && args+=(--hostname "$host")
  glab "${args[@]}" "$@"
}

case "$forge" in
  github) current=$(gh api "repos/${project}/pulls/${cr_iid}" --jq .head.sha 2>&1) \
            || fail "could not re-read the CR head: $(head -1 <<<"$current")" ;;
  gitlab) current=$(gl_api "projects/${gl_project}/merge_requests/${cr_iid}" 2>/dev/null \
            | jq -r '.diff_refs.head_sha // .sha // ""') \
            || fail "could not re-read the CR head" ;;
  *) fail "unknown forge: $forge" ;;
esac

[[ "$current" == "$pinned" ]] \
  || fail "head-moved: the CR is now at ${current}, the review was taken at ${pinned} — re-run /anchor:review against the new head rather than anchoring to lines that have moved"

posted_inline=0
posted_summary=0

post_summary() {
  local body path
  body=$(build_summary)
  [[ -n "$body" ]] || return 0
  path=$(anchor_tmpfile "cr-review-summary")
  printf '%s\n' "$body" > "$path"
  case "$forge" in
    github) gh pr comment "$cr_iid" -R "$project" --body-file "$path" >/dev/null ;;
    gitlab) gl_api -X POST "projects/${gl_project}/merge_requests/${cr_iid}/notes" \
              -F "body=@${path}" >/dev/null ;;
  esac
  posted_summary=1
}

# One inline thread, from a single findings entry passed as compact JSON.
post_one() {
  local entry="$1" path payload file start end side
  file=$(jq -r '.file' <<<"$entry")
  start=$(jq -r '.startLine' <<<"$entry")
  end=$(jq -r '.endLine // .startLine' <<<"$entry")
  side=$(jq -r '.side // "new"' <<<"$entry")
  path=$(anchor_tmpfile "cr-review-note")
  jq -r '.body' <<<"$entry" > "$path"

  case "$forge" in
    github)
      # side is LEFT/RIGHT on GitHub; the contract's old/new maps onto it.
      local gh_side="RIGHT"; [[ "$side" == old ]] && gh_side="LEFT"
      local args=(-X POST "repos/${project}/pulls/${cr_iid}/comments"
                  -F "body=@${path}" -f "commit_id=${pinned}" -f "path=${file}"
                  -F "line=${end}" -f "side=${gh_side}")
      [[ "$start" != "$end" ]] && args+=(-F "start_line=${start}" -f "start_side=${gh_side}")
      gh api "${args[@]}" >/dev/null
      ;;
    gitlab)
      # A flat -F "position[...]" is silently dropped and the note lands
      # unanchored, so the position goes in as one JSON document.
      payload=$(anchor_tmpfile "cr-review-discussion" json)
      jq -n --rawfile body "$path" \
        --arg base "$base_sha" --arg start_sha "$start_sha" --arg head "$pinned" \
        --arg path "$file" --argjson line "$end" --arg side "$side" '
        {body: $body,
         position: ({position_type: "text", base_sha: $base,
                     start_sha: $start_sha, head_sha: $head,
                     new_path: $path, old_path: $path}
                    + (if $side == "old" then {old_line: $line} else {new_line: $line} end))}
      ' > "$payload"
      local out
      out=$(gl_api -X POST "projects/${gl_project}/merge_requests/${cr_iid}/discussions" \
              --input "$payload" -H "Content-Type: application/json")
      # GitLab answers 201 for an unanchored note too, so confirm the position
      # survived rather than reporting a thread that landed at the bottom.
      [[ "$(jq -r '.notes[0].type // ""' <<<"$out")" == "DiffNote" ]] \
        || fail "GitLab dropped the position for ${file}:${end} — the note would have landed unanchored"
      ;;
  esac
  posted_inline=$((posted_inline + 1))
}

if [[ "$index" == "summary" ]]; then
  post_summary
elif [[ -n "$index" ]]; then
  entry=$(jq -c --argjson i "$index" '.[$i - 1] // empty' <<<"$anchored")
  [[ -n "$entry" ]] || fail "no anchored finding at index ${index} (there are ${anchored_count})"
  post_one "$entry"
elif [[ "$forge" == github && "$anchored_count" -gt 0 ]]; then
  # One batched review rather than N notifications. The review's own body is the
  # summary, so the separate summary comment is not also posted.
  payload=$(anchor_tmpfile "cr-review-batch" json)
  jq -n --arg commit "$pinned" --arg body "$(build_summary)" --argjson c "$anchored" '
    {commit_id: $commit, body: $body, event: "COMMENT",
     comments: [$c[] | {path: .file,
                        line: (.endLine // .startLine),
                        side: (if (.side // "new") == "old" then "LEFT" else "RIGHT" end)}
                       + (if (.endLine // .startLine) != .startLine
                          then {start_line: .startLine,
                                start_side: (if (.side // "new") == "old" then "LEFT" else "RIGHT" end)}
                          else {} end)
                       + {body: .body}]}
  ' > "$payload"
  gh api -X POST "repos/${project}/pulls/${cr_iid}/reviews" --input "$payload" >/dev/null
  posted_inline="$anchored_count"
  [[ -n "$(build_summary)" ]] && posted_summary=1
else
  while read -r entry; do
    [[ -z "$entry" ]] && continue
    post_one "$entry"
  done < <(jq -c '.[]' <<<"$anchored")
  post_summary
fi

echo "POSTED_INLINE=$posted_inline"
echo "POSTED_SUMMARY=$posted_summary"
