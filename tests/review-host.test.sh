#!/usr/bin/env bash
# Functional test for scripts/lib/review-host.sh (anchor_host_launch_script).
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
# shellcheck source=../scripts/lib/review-host.sh
source "$here/../scripts/lib/review-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-review-host-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# A space and a quote in the directory: both survive only through the quoting
# anchor_host_sq does, and a pane that loses either lands somewhere else.
target="$work/re po's repo"
mkdir -p "$target"

run_launch() {
  local script="$1" sentinel="$2"
  ( cd / && sh "$script" "$sentinel" )
}

# --- the pane runs in the directory the command was resolved against
launch="$work/launch-cwd.sh"
sentinel="$work/rc-cwd"
( cd "$target" && anchor_host_launch_script 'pwd -P > ../seen-cwd' > "$launch" )
run_launch "$launch" "$sentinel"
[ "$(cat "$work/seen-cwd")" = "$(cd "$target" && pwd -P)" ] || fail "pane ran in $(cat "$work/seen-cwd")"
ok "the pane runs in the caller's directory, quoting and all"

# --- the command's status reaches the sentinel, written whole via the .tmp swap.
# revdiff reports captured annotations as exit 10, which the adapter reads as a
# verdict, so a status the pane drops is a review that came back blank.
launch="$work/launch-rc.sh"
sentinel="$work/rc-status"
( cd "$target" && anchor_host_launch_script '( exit 10 )' > "$launch" )
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
  PATH="$work/bin:$PATH" EDITOR='my editor --wait' anchor_host_launch_script \
    'printf "%s\n%s\n" "$PATH" "$EDITOR" > ../seen-env' > "$launch"
)
run_launch "$launch" "$sentinel"
grep -q "^$work/bin:" "$work/seen-env"          || fail "PATH did not reach the pane"
grep -qx 'my editor --wait' "$work/seen-env"    || fail "EDITOR did not reach the pane"
ok "the caller's PATH and EDITOR reach the pane"

# --- an unset variable is left unset rather than exported empty, so the pane
# falls back the way the caller would rather than to an empty editor
launch="$work/launch-unset.sh"
( cd "$target" && env -u VISUAL bash -c "source '$here/../scripts/lib/review-host.sh'; anchor_host_launch_script ':'" > "$launch" )
if grep -q 'VISUAL' "$launch"; then fail "an unset VISUAL was exported anyway"; fi
ok "an unset variable is not exported"

# --- the dispatcher reaches the selected host's own runner. Driven through
# `gui`, the one host that needs no terminal to put up: it is what a blocking
# editor selects, and its runner evaluates the command string directly, so a
# marker the command leaves behind is proof the dispatch landed.
marker="$work/dispatched"
rc=0
( TMUX='' ANCHOR_HOST_RUNNER='' ITERM_SESSION_ID='' \
  anchor_host_run "touch '$marker'" edit 'fake-editor --wait' ) || rc=$?
[ "$rc" -eq 0 ]     || fail "the gui host should return the command's own status, got $rc"
[ -f "$marker" ]    || fail "the dispatcher never reached the host's runner"
ok "the dispatcher runs the command in the host it selected"

# --- and reports its own status where no host can be reached, rather than
# running the command somewhere it did not choose.
rc=0
( TMUX='' ANCHOR_HOST_RUNNER='' ITERM_SESSION_ID='' \
  anchor_host_run "touch '$work/never'" diff ) </dev/null || rc=$?
[ "$rc" -eq "$anchor_host_rc_no_pane" ] || fail "no host should report no-pane, got $rc"
[ ! -f "$work/never" ]                   || fail "the command ran with no host to run it in"
ok "with nowhere to open, the dispatcher runs nothing and says so"

# --- a result written as the host goes down is read, not discarded. Quitting the
# tool is what closes the pane, so every ordinary review ends with the status
# landing and the pane dying in the same breath; a liveness probe that happens to
# fall in that second answers for a moment already past. Before the sentinel was
# re-read, roughly one review in fifteen came back `pane-closed` with its verdict
# sitting unread on disk.
sentinel="$work/rc-quit"
: > "$sentinel"
( sleep 1.5
  printf %s 10 > "$sentinel.tmp" && mv -f "$sentinel.tmp" "$sentinel"
  touch "$sentinel.dead" ) &
probe_alive() { [ ! -e "$sentinel.dead" ]; }
rc=0
seen=$(anchor_host_probe_seconds=1 anchor_host_await "$sentinel" probe_alive x) || rc=$?
wait
[ "$rc" -eq 0 ]   || fail "a written status should be returned, not $rc"
[ "$seen" = 10 ]  || fail "the wait returned '$seen', want the 10 on disk"
ok "a status written as the pane closes is read rather than discarded"

# --- and a pane that closes having written nothing is still the abandoned review
# it always was.
sentinel="$work/rc-abandoned"
: > "$sentinel"
( sleep 1.5; touch "$sentinel.dead" ) &
rc=0
anchor_host_probe_seconds=1 anchor_host_await "$sentinel" probe_alive x >/dev/null 2>&1 || rc=$?
wait
[ "$rc" -eq "$anchor_host_rc_no_result" ] || fail "an empty sentinel should report no-result, got $rc"
ok "a pane closed without writing reports no-result"

echo "PASS: review-host"
