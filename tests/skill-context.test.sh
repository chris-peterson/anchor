#!/usr/bin/env bash
# Byte budgets and packaged phase reachability, including failure fixtures.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
checker="$root/scripts/check-skill-context.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

bash "$checker" "$root"

mkdir -p "$tmp/skills/example/references"
entry="$tmp/skills/example/SKILL.md"
phase="$tmp/skills/example/references/phase.md"

expect_failure() {
  local reason="$1"
  if bash "$checker" "$tmp" > "$tmp/output" 2>&1; then
    fail "accepted $reason"
  fi
  grep -qF "$reason" "$tmp/output" || fail "wrong diagnostic for $reason"
}

printf '[Phase](references/phase.md)\n' > "$entry"
printf 'Required procedure\n' > "$phase"
bash "$checker" "$tmp"
ok "a shipped phase resolves from its skill directory"

rm "$phase"
expect_failure 'missing references/phase.md'
printf 'Required procedure\n' > "$phase"
printf '# Example\n' > "$entry"
expect_failure 'phase is not linked'
ok "missing and unreachable phase files fail"

# Exactly at the budgets succeeds. The non-ASCII fixture ensures wc -c counts
# bytes rather than characters; 3,001 e-acute characters are 6,002 UTF-8 bytes.
printf '[Phase](references/phase.md)\n' > "$entry"
awk 'BEGIN { for (i=0; i<8000; i++) printf "x" }' > "$phase"
bash "$checker" "$tmp"
printf x >> "$phase"
expect_failure '8001 bytes exceeds 8000'
ok "phase budget is inclusive and enforced"

rm "$phase"
awk 'BEGIN { for (i=0; i<6000; i++) printf "x" }' > "$entry"
bash "$checker" "$tmp"
printf x >> "$entry"
expect_failure '6001 bytes exceeds 6000'
awk 'BEGIN { for (i=0; i<3001; i++) printf "\303\251" }' > "$entry"
expect_failure '6002 bytes exceeds 6000'
ok "entry budget is inclusive and measured in UTF-8 bytes"

rm "$entry"
expect_failure 'no skill entry points found'
ok "an empty package cannot pass the check"
