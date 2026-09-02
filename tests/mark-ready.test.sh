#!/usr/bin/env bash
# Functional test for scripts/mark-ready.sh.
#
# Drives the real script against stub `gh` / `glab` that serve a CR's JSON and
# record the mutation, so what is asserted is the invocation each forge gets and
# the announcement that follows it.
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
# whichever subcommand $FAIL_ON names.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
  "pr view")  [[ "$FAIL_ON" != view  ]] || { echo "no pull requests found" >&2; exit 1; }
              cat "$CR_JSON" ;;
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

# run <args...> — capture stdout, stderr and status, on a fresh call log.
run() {
  : > "$CALL_LOG"
  out=""; err=""; status=0
  local errfile="$work/err.txt"
  out="$(bash "$mark_ready_sh" "$@" 2>"$errfile")" || status=$?
  err="$(cat "$errfile")"
}

# --- GitHub, a draft ---------------------------------------------------------
printf '{"url":"https://github.com/o/r/pull/128","isDraft":true}\n' > "$CR_JSON"
run --forge github --cr 128
[[ "$status" -eq 0 ]] || fail "non-zero on a draft: $status $err"
echo "$out" | grep -q '^CR_URL=https://github.com/o/r/pull/128$' || fail "wrong CR_URL: $out"
echo "$out" | grep -q '^CR_READY=ok$' || fail "did not report the flag cleared: $out"
grep -q '^gh pr ready 128$' "$CALL_LOG" || fail "did not run gh pr ready: $(cat "$CALL_LOG")"
echo "$out" | grep -q '^codes\.bridgeai\.anchor/cr\.ready {"uri":"https://github.com/o/r/pull/128"}$' \
  || fail "wrong announcement: $out"
ok "GitHub: a draft is marked ready and announced with its URL"

# --- GitHub, already ready ---------------------------------------------------
printf '{"url":"https://github.com/o/r/pull/128","isDraft":false}\n' > "$CR_JSON"
run --forge github --cr 128
[[ "$status" -eq 0 ]] || fail "non-zero on an already-ready CR: $status $err"
echo "$out" | grep -q '^ALREADY_READY=1$' || fail "did not report already ready: $out"
echo "$out" | grep -q '^CR_READY=ok$' && fail "claimed to clear a clear flag: $out"
grep -q 'pr ready' "$CALL_LOG" && fail "mutated an already-ready CR: $(cat "$CALL_LOG")"
echo "$out" | grep -q 'cr\.ready' && fail "announced a transition that did not happen: $out"
ok "an already-ready CR is left alone, and announces nothing"

# --- GitLab, a draft ---------------------------------------------------------
printf '{"web_url":"https://gitlab.example.com/g/r/-/merge_requests/42","draft":true}\n' > "$CR_JSON"
run --forge gitlab --cr 42
[[ "$status" -eq 0 ]] || fail "non-zero on a GitLab draft: $status $err"
echo "$out" | grep -q '^CR_READY=ok$' || fail "did not report the flag cleared: $out"
grep -q '^glab mr update 42 --ready$' "$CALL_LOG" || fail "wrong glab call: $(cat "$CALL_LOG")"
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

# --- The mutation is refused -------------------------------------------------
FAIL_ON=ready run --forge github --cr 128
[[ "$status" -ne 0 ]] || fail "exited 0 when the mutation was refused"
echo "$err" | grep -q '^READY_ERROR=' || fail "no READY_ERROR on a refused mutation: $err"
echo "$out" | grep -q 'cr\.ready' && fail "announced a flag that never came off: $out"
ok "a refused mutation is an error, and announces nothing"

# --- Usage -------------------------------------------------------------------
FAIL_ON=""
for args in "--cr 128" "--forge bitbucket --cr 1" "--forge github" "--forge github --cr 1 --nope"; do
  # shellcheck disable=SC2086  # each case is a deliberate argv split
  run $args
  [[ "$status" -eq 64 ]] || fail "expected exit 64 for '$args', got $status"
  echo "$err" | grep -q '^READY_ERROR=' || fail "no READY_ERROR for '$args': $err"
done
ok "a missing or unrecognized argument is exit 64, before anything is read"

echo "PASS"
