#!/usr/bin/env bash
# Functional test for scripts/lib/size-stack.sh: the longest bar's length
# follows how big the largest pass in the stack is, so a small change draws
# small and a large one fills the width.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/size-stack.sh
source "$here/../scripts/lib/size-stack.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

# The cells in the longest coloured bar of a stack read on stdin. Counted in
# bytes, which every awk agrees on: each block glyph is three.
longest() {
  anchor_size_stack | LC_ALL=C awk '/^[+-]/ { s = $1; sub(/^[+-]/, "", s); n = length(s) / 3; if (n > m) m = n } END { print m + 0 }'
}

w=$ANCHOR_SIZE_STACK_WIDTH

[ "$(printf '\t3\t60\t40\n' | longest)" = $(( w / 3 )) ] || fail "a pass of 100 lines draws a third of the width"
ok "up to 100 lines: a third of the width"

[ "$(printf '\t3\t600\t300\n' | longest)" = $(( w * 2 / 3 )) ] || fail "a pass under 1000 lines draws two thirds of the width"
ok "under 1000 lines: two thirds"

[ "$(printf '\t3\t700\t300\n' | longest)" = "$w" ] || fail "a pass of 1000 lines draws the full width"
ok "1000 lines or more: the full width"

# Rounds rebalance: the scale is the largest pass in the stack drawn now, here
# the earlier round's 80 lines, whose bar is the longest.
stack=$(printf 'round 2\t1\t20\t5\nround 1\t3\t60\t20\n' | anchor_size_stack current)
[ "$(LC_ALL=C awk '/ \+60$/ { s = $1; print length(s) / 3 }' <<<"$stack")" = $(( w / 3 )) ] \
  || fail "a stack is scaled against the largest pass it holds: $stack"
ok "each draw is scaled to the largest pass it holds"

echo "all size-stack tests passed"
