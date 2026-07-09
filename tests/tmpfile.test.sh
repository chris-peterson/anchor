#!/usr/bin/env bash
# Functional test for scripts/lib/tmpfile.sh (anchor_tmpfile).
#
# Runs on ubuntu / macOS / Windows-Git-Bash in CI to challenge the assumption
# behind the fix: that a trailing-`XXXXXX` template with the suffix appended
# outside behaves identically regardless of which mktemp the shell resolves.
# macOS's default `mktemp` is BSD /usr/bin/mktemp — the binary that broke the
# old `mktemp NAME.XXXXXX.md` form and let a stale scratch file block a rerun.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/tmpfile.sh
source "$here/../scripts/lib/tmpfile.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

echo "# mktemp: $(command -v mktemp)"
mktemp --version 2>/dev/null | head -1 || echo "# (BSD mktemp: no --version)"

tmp="${TMPDIR:-/tmp}"; tmp="${tmp%/}" # match anchor_tmpfile's slash normalization

p1="$(anchor_tmpfile cr-desc-current)"
echo "# sample: $p1"
[[ "$p1" == *.md ]]     || fail "not .md: $p1";                    ok ".md suffix"
[[ "$p1" != *XXXXXX* ]] || fail "template not expanded (literal X): $p1"; ok "template expanded"
[[ "$p1" == "$tmp/"* ]] || fail "not under temp dir: $p1";         ok "under \$TMPDIR/tmp"

p2="$(anchor_tmpfile cr-desc-current)"
[[ "$p1" != "$p2" ]]    || fail "consecutive calls collided: $p1"; ok "unique across calls"

# Original bug scenario: a stale file at the *literal* template path, plus a
# prior generated file, must not block a fresh, writable name.
touch "$tmp/cr-desc-current.XXXXXX.md" "$p1"
p3="$(anchor_tmpfile cr-desc-current)"
[[ "$p3" != "$p1" && "$p3" != *XXXXXX* ]] || fail "stale leftovers blocked fresh name: $p3"
ok "fresh despite stale leftovers"
: > "$p3"; [[ -f "$p3" ]] || fail "not writable: $p3";             ok "writable"
rm -f "$tmp/cr-desc-current.XXXXXX.md" "$p1" "$p3"

pt="$(anchor_tmpfile issue-draft txt)"
[[ "$pt" == *.txt && "$pt" != *XXXXXX* ]] || fail "custom ext failed: $pt"; ok "custom extension"

echo "# all checks passed"
