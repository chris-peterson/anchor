#!/usr/bin/env bash
# Functional test for scripts/lib/split-run.sh (anchor_split_launch_script).
#
# The pane iTerm2 opens runs this generated script and nothing else, so what the
# script carries is the whole of the pane's context. The launch is AppleScript
# and unreachable from CI, but the script it hands over is plain text: the suite
# generates one and runs it, which is what the pane does.
#
# The directory is the part with teeth. A review arrives as git refs resolved
# against the repo review-diff.sh --repo picked, and the pane inherits iTerm2's
# directory rather than the caller's, so a script that does not cd renders the
# wrong repo's diff — or, where that repo is clean, nothing at all.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/split-run.sh
source "$here/../scripts/lib/split-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-split-run-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# A space and a quote in the directory: both survive only through the quoting
# anchor_split_sq does, and a pane that loses either lands somewhere else.
target="$work/re po's repo"
mkdir -p "$target"

run_launch() {
  local script="$1" sentinel="$2"
  ( cd / && sh "$script" "$sentinel" )
}

# --- the pane runs in the directory the command was resolved against
launch="$work/launch-cwd.sh"
sentinel="$work/rc-cwd"
( cd "$target" && anchor_split_launch_script 'pwd -P > ../seen-cwd' > "$launch" )
run_launch "$launch" "$sentinel"
[ "$(cat "$work/seen-cwd")" = "$(cd "$target" && pwd -P)" ] || fail "pane ran in $(cat "$work/seen-cwd")"
ok "the pane runs in the caller's directory, quoting and all"

# --- the command's status reaches the sentinel, written whole via the .tmp swap.
# revdiff reports captured annotations as exit 10, which the adapter reads as a
# verdict, so a status the pane drops is a review that came back blank.
launch="$work/launch-rc.sh"
sentinel="$work/rc-status"
( cd "$target" && anchor_split_launch_script '( exit 10 )' > "$launch" )
run_launch "$launch" "$sentinel"
[ "$(cat "$sentinel")" = 10 ] || fail "sentinel holds $(cat "$sentinel"), want 10"
ok "the command's own status reaches the sentinel"

# --- the caller's PATH and editor reach the pane, which starts on neither
launch="$work/launch-env.sh"
sentinel="$work/rc-env"
(
  cd "$target"
  # $PATH and $EDITOR belong to the pane's shell, not to this one.
  # shellcheck disable=SC2016
  PATH="$work/bin:$PATH" EDITOR='my editor --wait' anchor_split_launch_script \
    'printf "%s\n%s\n" "$PATH" "$EDITOR" > ../seen-env' > "$launch"
)
run_launch "$launch" "$sentinel"
grep -q "^$work/bin:" "$work/seen-env"          || fail "PATH did not reach the pane"
grep -qx 'my editor --wait' "$work/seen-env"    || fail "EDITOR did not reach the pane"
ok "the caller's PATH and EDITOR reach the pane"

# --- an unset variable is left unset rather than exported empty, so the pane
# falls back the way the caller would rather than to an empty editor
launch="$work/launch-unset.sh"
( cd "$target" && env -u VISUAL bash -c "source '$here/../scripts/lib/split-run.sh'; anchor_split_launch_script ':'" > "$launch" )
if grep -q 'VISUAL' "$launch"; then fail "an unset VISUAL was exported anyway"; fi
ok "an unset variable is not exported"

echo "PASS: split-run"
