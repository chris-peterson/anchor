#!/usr/bin/env bash
# Functional test for scripts/review-post.sh.
#
# Two properties carry this script. First, the previewed text and the posted
# text are built from one findings document through one path, so a diff between
# them would mean the user approved something other than what landed
# (REVIEW-14). Second, the head SHA pinned when the diff was fetched is re-read
# before the first write: an author who pushes mid-review moves every line an
# anchor points at, and posting anyway lands comments on a diff nobody read
# (REVIEW-11).
#
# The forge halves are asymmetric and the stubs capture that: GitHub takes the
# whole review as one submission, GitLab takes one POST per thread and answers
# 201 even when it dropped the position — which is why the script inspects the
# note type rather than the status.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
review_post_sh="$here/../scripts/review-post.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-review-post-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub gh: logs every call, serves $CURRENT_HEAD for the head re-read, and
# --- captures a --input payload so the batched review can be asserted on.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CALL_LOG"
case "${1:-}" in
  api)
    if [[ "$*" == *".head.sha"* ]]; then echo "$CURRENT_HEAD"; exit 0; fi
    if [[ "$*" == *"/reviews"* ]]; then
      for ((i=1; i<=$#; i++)); do
        [[ "${!i}" == "--input" ]] && { j=$((i+1)); cp "${!j}" "$PAYLOAD_LOG"; }
      done
      echo '{"id":1}'; exit 0
    fi
    if [[ "$*" == *"/comments"* ]]; then echo '{"id":2}'; exit 0; fi
    echo "stub gh: unhandled api call: $*" >&2; exit 1 ;;
  pr)
    [[ "${2:-}" == comment ]] || { echo "stub gh: unhandled pr ${2:-}" >&2; exit 1; }
    for ((i=1; i<=$#; i++)); do
      [[ "${!i}" == "--body-file" ]] && { j=$((i+1)); cp "${!j}" "$SUMMARY_LOG"; }
    done
    echo "https://github.com/example/repo/pull/7#issuecomment-1" ;;
  *) echo "stub gh: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

# --- stub glab: same, plus the DiffNote/DiscussionNote distinction. With
# --- $GL_DROP_POSITION=1 it answers the way GitLab does when the position was
# --- malformed — 201, but the note landed unanchored.
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'glab %s\n' "$*" >> "$CALL_LOG"
[[ "${1:-}" == api ]] || { echo "stub glab: unhandled command: ${1:-}" >&2; exit 1; }
if [[ "$*" == *"/discussions"* ]]; then
  for ((i=1; i<=$#; i++)); do
    [[ "${!i}" == "--input" ]] && { j=$((i+1)); cat "${!j}" >> "$PAYLOAD_LOG"; }
  done
  if [[ "${GL_DROP_POSITION:-0}" == 1 ]]; then
    echo '{"notes":[{"type":"DiscussionNote","position":null}]}'
  else
    echo '{"notes":[{"type":"DiffNote"}]}'
  fi
  exit 0
fi
if [[ "$*" == *"/notes"* ]]; then
  for ((i=1; i<=$#; i++)); do
    [[ "${!i}" == -F ]] && { j=$((i+1)); v="${!j}"; [[ "$v" == body=@* ]] && cp "${v#body=@}" "$SUMMARY_LOG"; }
  done
  echo '{"id":3}'; exit 0
fi
# The head re-read.
printf '{"sha":"%s","diff_refs":{"head_sha":"%s"}}\n' "$CURRENT_HEAD" "$CURRENT_HEAD"
EOF

chmod +x "$bin/gh" "$bin/glab"
PATH="$bin:$PATH"
export PATH

export CALL_LOG="$work/calls.log"
export PAYLOAD_LOG="$work/payload.json"
export SUMMARY_LOG="$work/summary.md"
export CURRENT_HEAD="headsha1"

key() { sed -n "s/^$2=//p" <<<"$1"; }
reset_logs() { : > "$CALL_LOG"; : > "$PAYLOAD_LOG"; : > "$SUMMARY_LOG"; }

findings="$work/findings.json"
cat > "$findings" <<'EOF'
{
  "cr": {"url": "https://example/7", "headSha": "headsha1"},
  "summary": "The rename reads well; the cache key is the part worth a second look.",
  "comments": [
    {"body": "Dropping the tenant here means two tenants share an entry.",
     "target": "line", "file": "src/cache.js", "startLine": 42, "endLine": 42,
     "side": "new", "origin": "reviewer"},
    {"body": "This whole block only runs when the flag is off.",
     "target": "line", "file": "src/flag.js", "startLine": 10, "endLine": 14,
     "side": "old", "origin": "agent"},
    {"body": "Nothing covers the new branch.", "target": "changeset", "origin": "reviewer"},
    {"body": "Reads as dead code now.", "target": "file", "file": "src/legacy.js", "origin": "agent"}
  ]
}
EOF

# --- Preview: anchorable findings numbered, the rest folded into the summary --
preview=$(bash "$review_post_sh" --preview --findings "$findings")
[[ "$preview" == *"Inline threads (2)"* ]] || fail "preview: expected 2 inline threads"
[[ "$preview" == *"src/cache.js:42"* ]]    || fail "preview: missing the single-line anchor"
[[ "$preview" == *"src/flag.js:10-14"* ]]  || fail "preview: missing the multi-line range"
[[ "$preview" == *"Nothing covers the new branch."* ]] || fail "preview: changeset finding dropped"
[[ "$preview" == *"**src/legacy.js** — Reads as dead code now."* ]] \
  || fail "preview: file-target finding not named with its file"
ok "preview: anchors what it can and folds the rest into the summary (REVIEW-08)"

# --- GitHub: the whole review posts as one submission ------------------------
reset_logs
out=$(bash "$review_post_sh" --post --findings "$findings" \
        --forge github --project example/repo --cr 7)
[[ "$(key "$out" POSTED_INLINE)" == 2 ]]  || fail "GitHub: POSTED_INLINE=$(key "$out" POSTED_INLINE)"
[[ "$(key "$out" POSTED_SUMMARY)" == 1 ]] || fail "GitHub: POSTED_SUMMARY=$(key "$out" POSTED_SUMMARY)"
[[ "$(grep -c '/pulls/7/reviews' "$CALL_LOG")" -eq 1 ]] \
  || fail "GitHub: expected exactly one batched review call"
[[ "$(grep -c '/pulls/7/comments' "$CALL_LOG")" -eq 0 ]] \
  || fail "GitHub: batched path should not also post individual comments"
ok "GitHub: batches the review into one submission (REVIEW-12)"

[[ "$(jq -r '.event' "$PAYLOAD_LOG")" == COMMENT ]] \
  || fail "GitHub: event should be COMMENT, not a recorded verdict"
[[ "$(jq -r '.commit_id' "$PAYLOAD_LOG")" == headsha1 ]] || fail "GitHub: commit_id not the pinned head"
[[ "$(jq -r '.comments | length' "$PAYLOAD_LOG")" == 2 ]] || fail "GitHub: wrong comment count"
[[ "$(jq -r '.comments[0].side' "$PAYLOAD_LOG")" == RIGHT ]] || fail "GitHub: new side should map to RIGHT"
[[ "$(jq -r '.comments[1].side' "$PAYLOAD_LOG")" == LEFT ]]  || fail "GitHub: old side should map to LEFT"
[[ "$(jq -r '.comments[1].start_line' "$PAYLOAD_LOG")" == 10 ]] || fail "GitHub: multi-line start_line"
[[ "$(jq -r '.comments[1].line' "$PAYLOAD_LOG")" == 14 ]] || fail "GitHub: multi-line line should be the last"
ok "GitHub: never records a verdict, and maps old/new onto LEFT/RIGHT"

# The review body is the previewed summary, byte for byte (REVIEW-14).
[[ "$(jq -r '.body' "$PAYLOAD_LOG")" == *"Nothing covers the new branch."* ]] \
  || fail "GitHub: the review body is not the rendered summary"
ok "GitHub: the posted summary is the previewed one (REVIEW-14)"

# --- GitHub: --index posts exactly one finding -------------------------------
reset_logs
out=$(bash "$review_post_sh" --post --findings "$findings" \
        --forge github --project example/repo --cr 7 --index 1)
[[ "$(key "$out" POSTED_INLINE)" == 1 ]]  || fail "GitHub --index: POSTED_INLINE"
[[ "$(key "$out" POSTED_SUMMARY)" == 0 ]] || fail "GitHub --index: should not post the summary"
[[ "$(grep -c '/pulls/7/comments' "$CALL_LOG")" -eq 1 ]] \
  || fail "GitHub --index: expected one individual comment call"
ok "GitHub: --index posts one finding and leaves the rest (REVIEW-12)"

# --- GitLab: one POST per thread, then the summary note ----------------------
reset_logs
out=$(bash "$review_post_sh" --post --findings "$findings" \
        --forge gitlab --project 'grp/sub/repo' --cr 7 \
        --base-sha basesha --start-sha startsha)
[[ "$(key "$out" POSTED_INLINE)" == 2 ]]  || fail "GitLab: POSTED_INLINE=$(key "$out" POSTED_INLINE)"
[[ "$(key "$out" POSTED_SUMMARY)" == 1 ]] || fail "GitLab: POSTED_SUMMARY"
[[ "$(grep -c '/discussions' "$CALL_LOG")" -eq 2 ]] || fail "GitLab: expected two discussion POSTs"
[[ "$(grep -c 'grp%2Fsub%2Frepo' "$CALL_LOG")" -ge 2 ]] \
  || fail "GitLab: nested project path not URL-encoded in place of :fullpath"
ok "GitLab: one POST per thread against the encoded project path"

first=$(jq -sr '.[0]' "$PAYLOAD_LOG")
[[ "$(jq -r '.position.position_type' <<<"$first")" == text ]] || fail "GitLab: position_type"
[[ "$(jq -r '.position.head_sha' <<<"$first")" == headsha1 ]]  || fail "GitLab: head_sha not the pinned head"
[[ "$(jq -r '.position.base_sha' <<<"$first")" == basesha ]]   || fail "GitLab: base_sha"
[[ "$(jq -r '.position.start_sha' <<<"$first")" == startsha ]] || fail "GitLab: start_sha"
[[ "$(jq -r '.position.new_line' <<<"$first")" == 42 ]] || fail "GitLab: new_line"
second=$(jq -sr '.[1]' "$PAYLOAD_LOG")
[[ "$(jq -r '.position.old_line' <<<"$second")" == 14 ]] || fail "GitLab: old side should set old_line"
[[ "$(jq -r '.position.new_line' <<<"$second")" == null ]] || fail "GitLab: old side should not set new_line"
ok "GitLab: the position pins all three SHAs and picks the side's line field"

# --- GitLab: a dropped position is a failure, not a posted comment -----------
reset_logs
GL_DROP_POSITION=1
export GL_DROP_POSITION
set +e
out=$(bash "$review_post_sh" --post --findings "$findings" \
        --forge gitlab --project example/repo --cr 7 \
        --base-sha basesha --start-sha startsha 2>/dev/null)
rc=$?
set -e
unset GL_DROP_POSITION
[[ $rc -ne 0 ]] || fail "GitLab: expected a non-zero exit when the position was dropped"
[[ "$(key "$out" POST_ERROR)" == *"unanchored"* ]] || fail "GitLab: expected an unanchored POST_ERROR, got: $out"
ok "GitLab: a 201 that dropped the position is reported, not counted as posted"

# --- The head moved since the review was taken -------------------------------
reset_logs
CURRENT_HEAD="headsha2"
set +e
out=$(bash "$review_post_sh" --post --findings "$findings" \
        --forge github --project example/repo --cr 7 2>/dev/null)
rc=$?
set -e
CURRENT_HEAD="headsha1"
[[ $rc -ne 0 ]] || fail "expected a non-zero exit when the head moved"
[[ "$(key "$out" POST_ERROR)" == head-moved* ]] || fail "expected a head-moved POST_ERROR, got: $out"
[[ "$(grep -c 'reviews\|comments' "$CALL_LOG")" -eq 0 ]] \
  || fail "posted despite the head having moved"
ok "a moved head refuses before anything is written (REVIEW-11)"

# --- A findings file with no pinned head is refused --------------------------
unpinned="$work/unpinned.json"
jq 'del(.cr.headSha)' "$findings" > "$unpinned"
set +e
out=$(bash "$review_post_sh" --post --findings "$unpinned" \
        --forge github --project example/repo --cr 7 2>/dev/null)
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "expected a non-zero exit with no pinned head"
[[ "$(key "$out" POST_ERROR)" == *"headSha"* ]] || fail "expected a headSha POST_ERROR, got: $out"
ok "an unpinned findings file is refused rather than posted against the live head"

# --- A review with nothing to say still posts its summary --------------------
reset_logs
empty="$work/empty.json"
jq '.comments = []' "$findings" > "$empty"
out=$(bash "$review_post_sh" --post --findings "$empty" \
        --forge github --project example/repo --cr 7)
[[ "$(key "$out" POSTED_INLINE)" == 0 ]]  || fail "empty: POSTED_INLINE"
[[ "$(key "$out" POSTED_SUMMARY)" == 1 ]] || fail "empty: the summary should still post"
ok "a review with no inline findings still lands its summary"

echo "# all checks passed"
