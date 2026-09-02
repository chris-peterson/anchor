#!/usr/bin/env bash
# Functional test for scripts/announce.sh, plus the drift trap tying plugin.yml's
# declared events to the source that emits them.
#
# The contract it holds up is the canonical guide:
# https://github.com/chris-peterson/claude-marketplace/blob/main/authoring/plugin-contract.md
#
# Two of its rules are what most of the assertions are for. The exit status,
# because announce.sh runs after the work it describes has landed and a non-zero
# would turn a CR that was written into a tool call that failed. And the
# one-line guarantee, which with a JSON body is structural rather than a rule:
# whatever a value holds, `jq -c` escapes it instead of emitting it.
#
# The drift trap is the other half. A manifest that drives documentation goes
# stale silently, because nothing fails when it does — so a key declared in
# plugin.yml and a key passed to announce.sh have to name each other.
# ci-platforms: linux macos windows

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
announce="$root/scripts/announce.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

# --- the drift trap: plugin.yml and the source must name the same keys --------
#
# Runs first, and without jq, so it still guards on a host where the emission
# tests below skip.

declared_keys() {
  awk '/^  publishes:/{in_block=1; next}
       /^  [a-z]/{in_block=0}
       in_block && /^    - key:/{print $3}' "$root/plugin.yml"
}

# Keys actually passed to the publisher. announce.sh itself is excluded: its
# header carries a usage example, which is documentation rather than a call site.
emitted_keys() {
  grep -rhoE 'announce\.sh"? +[a-z0-9]+\.[a-z0-9]+' \
    "$root/scripts" "$root/skills" \
    --exclude=announce.sh \
    | grep -oE '[a-z0-9]+\.[a-z0-9]+$' | sort -u
}

declared=$(declared_keys | sort -u)
emitted=$(emitted_keys)

[[ -n "$declared" ]] || fail "no events declared in plugin.yml — did the block move?"
echo "# declared: $(echo "$declared" | tr '\n' ' ')"
echo "# emitted:  $(echo "$emitted" | tr '\n' ' ')"

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  grep -rqF "$key" "$root/scripts" "$root/skills" \
    || fail "plugin.yml declares '$key' but no source emits it"
done <<<"$declared"
ok "every declared event appears in the source that emits it"

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  printf '%s\n' "$declared" | grep -qxF "$key" \
    || fail "source emits '$key' but plugin.yml does not declare it"
done <<<"$emitted"
ok "every emitted event is declared in plugin.yml"

# docs/events.md is hand-written prose, so the manifest is what keeps it honest.
# The key is checked fully-qualified, because that page is read by whoever is
# about to subscribe and the prefix is what they have to match on. The heading is
# checked for its explicit `:id=`, since a dotted heading does not slugify to
# anything a reader would guess, and each event has to be linkable on its own.
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  grep -qF "codes.bridgeai.anchor/$key" "$root/docs/events.md" \
    || fail "plugin.yml declares '$key' but docs/events.md does not document it"
  grep -qF "## \`$key\` :id=" "$root/docs/events.md" \
    || fail "docs/events.md has no anchored heading for '$key'"
done <<<"$declared"
ok "every declared event has an anchored section on the docs site"

# --- the publisher ------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping the emission checks"
  echo "PASS"
  exit 0
fi

# run <args...> — capture stdout, stderr and status without tripping set -e.
run() {
  out=""; err=""; status=0
  local errfile; errfile="$(mktemp)"
  out="$(bash "$announce" "$@" 2>"$errfile")" || status=$?
  err="$(cat "$errfile")"; rm -f "$errfile"
}

run cr.created uri=https://github.com/o/r/pull/88 title="Add a thing"
[[ "$out" == 'codes.bridgeai.anchor/cr.created {"uri":"https://github.com/o/r/pull/88","title":"Add a thing"}' ]] \
  || fail "unexpected line: $out"
ok "emits the key and a compact JSON body"

[[ "$(printf '%s' "$out" | wc -l | tr -d ' ')" == "0" ]] || fail "more than one line: $out"
ok "exactly one line"

run cr.created
[[ "$out" == "codes.bridgeai.anchor/cr.created {}" ]] || fail "empty body wrong: $out"
ok "an event with no fields still carries a body"

# The plugin segment is fixed, so anchor cannot announce on a sibling's behalf.
[[ "$out" == "codes.bridgeai.anchor/"* ]] || fail "plugin segment not anchor: $out"
ok "plugin segment is anchor"

# What the JSON body bought: a value may now hold anything at all.
#
# Each round-trip is asserted *inside* jq, against a JSON string literal in the
# program itself. Comparing jq's decoded output to a shell `printf` instead made
# the newline case a test of the host's line endings: Git Bash's jq writes CRLF,
# so the two sides differed on Windows over a value announce.sh had encoded
# correctly.
run cr.created 'title=spaces "quotes" and back\slashes'
printf '%s' "${out#* }" | jq -e '.title == "spaces \"quotes\" and back\\slashes"' >/dev/null \
  || fail "value did not round-trip: $out"
ok "a value carrying spaces, quotes and backslashes round-trips"

# The structural guarantee: a newline in a value cannot become a newline on the wire.
run cr.created "$(printf 'title=line one\nline two')"
[[ "$(printf '%s' "$out" | wc -l | tr -d ' ')" == "0" ]] \
  || fail "a newline in a value broke the line: $out"
[[ "$out" == *'line one\nline two'* ]] || fail "newline not escaped: $out"
printf '%s' "${out#* }" | jq -e '.title == "line one\nline two"' >/dev/null \
  || fail "newline did not round-trip: $out"
ok "a newline in a value is escaped, so the announcement stays one line"

for bad in "CR.Created" "crcreated" "cr.created.twice" "" "Cr.Created"; do
  run "$bad" uri=x
  [[ -z "$out" ]]       || fail "emitted for malformed key '$bad': $out"
  [[ "$status" -eq 0 ]] || fail "non-zero for malformed key '$bad': $status"
  [[ -n "$err" ]]       || fail "silent on malformed key '$bad'"
done
ok "malformed keys are refused, on stderr, still exit 0"

for bad in "URI=x" "Uri=x" "1uri=x" "uri" "=x"; do
  run cr.created "$bad"
  [[ -z "$out" ]]       || fail "emitted for malformed field '$bad': $out"
  [[ "$status" -eq 0 ]] || fail "non-zero for malformed field '$bad': $status"
done
ok "malformed field names are refused, still exit 0"

run
[[ "$status" -eq 0 ]] || fail "non-zero with no arguments: $status"
ok "no arguments still exits 0"

# jq builds the body, and there is no `command -v jq` guard because a missing one
# arrives as a non-zero from the encode. Exercised rather than assumed: this is
# the degraded path, which is never the input in front of you.
nojq_err="$(mktemp)"
nojq_out="$(PATH=/var/empty "$BASH" "$announce" cr.created uri=https://x/1 2>"$nojq_err")"
nojq_status=$?
[[ "$nojq_status" -eq 0 ]] || fail "non-zero with jq absent: $nojq_status"
[[ -z "$nojq_out" ]]       || fail "emitted a body with jq absent: $nojq_out"
[[ -s "$nojq_err" ]]       || fail "silent with jq absent"
rm -f "$nojq_err"
ok "with jq absent it says so on stderr, emits nothing, and still exits 0"

echo "PASS"
