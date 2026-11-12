#!/usr/bin/env bash
# Functional test for scripts/mark-ready.sh.
#
# Drives the real script against stub `gh` / `glab` that serve a CR's JSON and
# record the mutation, so what is asserted is the invocation each forge gets and
# the announcement that follows it, and the CR saved before the flag comes off
# (FORGE-13).
#
# The load-bearing case is the CR that is already ready. The flag flips live, so
# the script reads it rather than trusting the caller, and `cr.ready` names a
# transition — announcing one for a CR that was already clear would report
# something that never happened. The failure paths are here for the same reason
# from the other side: nothing may announce unless the flag actually moved.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mark_ready_sh="$here/../scripts/mark-ready.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  echo "PASS"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-mark-ready-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# Both stubs read the CR from $CR_JSON, append every call to $CALL_LOG, and fail
# whichever subcommand $FAIL_ON names. The backup's read (the PR view that asks
# for labels, the MR API GET) serves $BACKUP_JSON where a test sets it.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
  "pr view")  [[ "$FAIL_ON" != view  ]] || { echo "no pull requests found" >&2; exit 1; }
              if [[ "$*" == *labels* ]]; then cat "${BACKUP_JSON:-$CR_JSON}"; else cat "$CR_JSON"; fi ;;
  "pr ready") [[ "$FAIL_ON" != ready ]] || { echo "GraphQL: not permitted" >&2; exit 1; } ;;
  *) echo "stub gh: unhandled command: $*" >&2; exit 1 ;;
esac
EOF

cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "glab $*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
  "mr view")   [[ "$FAIL_ON" != view  ]] || { echo "404 not found" >&2; exit 1; }
               cat "$CR_JSON" ;;
  "mr update") [[ "$FAIL_ON" != ready ]] || { echo "403 forbidden" >&2; exit 1; } ;;
  "api projects/"*) cat "${BACKUP_JSON:-$CR_JSON}" ;;
  *) echo "stub glab: unhandled command: $*" >&2; exit 1 ;;
esac
EOF

chmod +x "$bin/gh" "$bin/glab"
PATH="$bin:$PATH"
export PATH

CR_JSON="$work/cr.json"
CALL_LOG="$work/calls.log"
FAIL_ON=""
export CR_JSON CALL_LOG FAIL_ON

# The backup goes under the git dir of the checkout the run is in, and reads the
# forge origin names, so each forge gets a scratch repo.
for name in github:github.com/o/r gitlab:gitlab.example.com/g/r; do
  git init --quiet -b main "$work/${name%%:*}"
  git -C "$work/${name%%:*}" remote add origin "https://${name#*:}.git"
done

# run <args...> — capture stdout, stderr and status, on a fresh call log, in the
# checkout for --forge.
run() {
  : > "$CALL_LOG"
  out=""; err=""; status=0
  local errfile="$work/err.txt" repo="$work/github" a
  for a in "$@"; do [[ "$a" != gitlab ]] || repo="$work/gitlab"; done
  out="$(cd "$repo" && bash "$mark_ready_sh" "$@" 2>"$errfile")" || status=$?
  err="$(cat "$errfile")"
}

# --- GitHub, a draft ---------------------------------------------------------
printf '{"url":"https://github.com/o/r/pull/128","isDraft":true}\n' > "$CR_JSON"
run --forge github --cr 128
[[ "$status" -eq 0 ]] || fail "non-zero on a draft: $status $err"
echo "$out" | grep -q '^CR_URL=https://github.com/o/r/pull/128$' || fail "wrong CR_URL: $out"
echo "$out" | grep -q '^CR_READY=ok$' || fail "did not report the flag cleared: $out"
grep -q '^gh pr ready 128$' "$CALL_LOG" || fail "did not run gh pr ready: $(cat "$CALL_LOG")"
backup=$(sed -n 's/^CR_BACKUP_PATH=//p' <<<"$out")
[[ "$backup" == */github/.git/anchor/backups/* ]] || fail "the draft CR should be saved under .git/anchor/backups: $out"
jq -e '.isDraft == true' "$backup" >/dev/null || fail "the backup should hold the CR as a draft: $(cat "$backup")"
echo "$out" | grep -q '^codes\.bridgeai\.anchor/cr\.ready {"uri":"https://github.com/o/r/pull/128"}$' \
  || fail "wrong announcement: $out"
ok "GitHub: a draft is saved, marked ready, and announced with its URL"

# --- GitHub, already ready ---------------------------------------------------
printf '{"url":"https://github.com/o/r/pull/128","isDraft":false}\n' > "$CR_JSON"
run --forge github --cr 128
[[ "$status" -eq 0 ]] || fail "non-zero on an already-ready CR: $status $err"
echo "$out" | grep -q '^ALREADY_READY=1$' || fail "did not report already ready: $out"
echo "$out" | grep -q '^CR_READY=ok$' && fail "claimed to clear a clear flag: $out"
grep -q 'pr ready' "$CALL_LOG" && fail "mutated an already-ready CR: $(cat "$CALL_LOG")"
echo "$out" | grep -q 'cr\.ready' && fail "announced a transition that did not happen: $out"
echo "$out" | grep -q '^CR_BACKUP_PATH=' && fail "backed up a CR it does not edit: $out"
ok "an already-ready CR is left alone, and announces nothing"

# --- GitLab, a draft ---------------------------------------------------------
printf '{"web_url":"https://gitlab.example.com/g/r/-/merge_requests/42","draft":true}\n' > "$CR_JSON"
run --forge gitlab --cr 42
[[ "$status" -eq 0 ]] || fail "non-zero on a GitLab draft: $status $err"
echo "$out" | grep -q '^CR_READY=ok$' || fail "did not report the flag cleared: $out"
grep -q '^glab mr update 42 --ready$' "$CALL_LOG" || fail "wrong glab call: $(cat "$CALL_LOG")"
[[ -f "$(sed -n 's/^CR_BACKUP_PATH=//p' <<<"$out")" ]] || fail "the MR should be saved before the flag comes off: $out"
echo "$out" | grep -q '"uri":"https://gitlab.example.com/g/r/-/merge_requests/42"' \
  || fail "wrong announcement: $out"
ok "GitLab: the flag comes off with mr update --ready, read from web_url and draft"

# --- The CR cannot be read ---------------------------------------------------
printf '{"url":"https://github.com/o/r/pull/128","isDraft":true}\n' > "$CR_JSON"
FAIL_ON=view run --forge github --cr 128
[[ "$status" -ne 0 ]] || fail "exited 0 when the CR could not be read"
echo "$err" | grep -q '^READY_ERROR=' || fail "no READY_ERROR on a failed read: $err"
echo "$out" | grep -q 'cr\.ready' && fail "announced after a failed read: $out"
ok "a CR that cannot be read is an error, and announces nothing"

# --- The backup reaches another CR -------------------------------------------
printf '{"url":"https://github.com/o/r/pull/129","isDraft":true}\n' > "$work/other.json"
BACKUP_JSON="$work/other.json" run --forge github --cr 128
[[ "$status" -ne 0 ]] || fail "exited 0 when the backup saved another CR"
echo "$err" | grep -q '^READY_ERROR=could not back up CR 128.*pull/129, not .*pull/128.*refusing' \
  || fail "the refusal should name both CRs: $err"
grep -q 'pr ready' "$CALL_LOG" && fail "marked ready after a mismatched backup: $(cat "$CALL_LOG")"
echo "$out" | grep -q 'cr\.ready' && fail "announced after a mismatched backup: $out"
ok "a backup of a CR other than the one read stops the edit"

# --- The mutation is refused -------------------------------------------------
FAIL_ON=ready run --forge github --cr 128
[[ "$status" -ne 0 ]] || fail "exited 0 when the mutation was refused"
echo "$err" | grep -q '^READY_ERROR=' || fail "no READY_ERROR on a refused mutation: $err"
echo "$out" | grep -q 'cr\.ready' && fail "announced a flag that never came off: $out"
ok "a refused mutation is an error, and announces nothing"

# --- The branch's CR, with the forge read off origin ---------------------------
printf '{"url":"https://github.com/o/r/pull/128","isDraft":true,"number":128,"title":"T","state":"OPEN","headRefOid":"abc","headRefName":"feat"}\n' > "$CR_JSON"
run --check
[[ "$status" -eq 0 ]] || fail "--check exited $status: $err"
for kv in FORGE=github CR_NUMBER=128 CR_REF=r#128 CR_STATE=open CR_DRAFT=true CR_HEAD_SHA=abc LOCAL_STATE=elsewhere; do
  echo "$out" | grep -qx "$kv" || fail "--check should report $kv: $out"
done
grep -q '^gh pr view --json' "$CALL_LOG" || fail "the CR should be the branch's, not a named one: $(cat "$CALL_LOG")"
grep -q 'pr ready' "$CALL_LOG" && fail "--check changed the CR: $(cat "$CALL_LOG")"
echo "$out" | grep -q 'CR_BACKUP_PATH=\|cr\.ready' && fail "--check backed up or announced: $out"
ok "--check reads the branch's CR off origin's forge and changes nothing"

run
[[ "$status" -eq 0 ]] || fail "the inferred mark-ready exited $status: $err"
grep -q '^gh pr ready 128$' "$CALL_LOG" || fail "the inferred CR's number should be marked ready: $(cat "$CALL_LOG")"
echo "$out" | grep -q '^CR_READY=ok$' || fail "did not report the flag cleared: $out"
ok "with no --cr, the branch's open CR is marked ready"

printf '{"url":"https://github.com/o/r/pull/128","isDraft":true,"number":128,"state":"MERGED"}\n' > "$CR_JSON"
run
[[ "$status" -eq 65 ]] || fail "a merged CR should exit 65, got $status"
echo "$err" | grep -q '^READY_ERROR=r#128 is merged, not open$' || fail "the state should be named: $err"
grep -q 'pr ready' "$CALL_LOG" && fail "marked a merged CR ready: $(cat "$CALL_LOG")"
ok "a CR that isn't open is exit 65, and is left alone"

# --- Usage -------------------------------------------------------------------
FAIL_ON=""
for args in "--forge bitbucket --cr 1" "--forge github --cr 1 --nope" "--forge github --cr 1 --repo"; do
  # shellcheck disable=SC2086  # each case is a deliberate argv split
  run $args
  [[ "$status" -eq 64 ]] || fail "expected exit 64 for '$args', got $status"
  echo "$err" | grep -q '^READY_ERROR=' || fail "no READY_ERROR for '$args': $err"
done
ok "a missing or unrecognized argument is exit 64, before anything is read"

echo "PASS"
