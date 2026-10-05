#!/usr/bin/env bash
# agterm — a review host. Sourced by scripts/lib/review-host.sh; the contract
# these functions answer to is documented at the top of that file.
#
# A floating program overlay on the calling session, agterm's counterpart to a
# tmux popup: it takes the keyboard while it is up, borrows no layout of the
# user's, and closes itself when the command exits. A split would be the iTerm2
# shape, but an agterm session holds one split at most, so a session that
# already has one could not be shown a review at all.
#
# AGTERM_SESSION_ID rather than TERM_PROGRAM: the overlay opens on the *calling
# session*, and `--target` defaults to whichever session the user has selected,
# which is not necessarily the one waiting on the review. The socket has to be
# live as well: an agterm instance that lost the socket to another advertises a
# path nothing listens on.

review_host_available() {
  [[ -n "${AGTERM_SESSION_ID:-}" && -S "${AGTERM_SOCKET:-}" ]] || return 1
  command -v agtermctl >/dev/null 2>&1
}

agterm_ctl() {
  agtermctl "$@" --target "$AGTERM_SESSION_ID" --socket "$AGTERM_SOCKET"
}

# Is the overlay still on screen? "Cannot tell" answers yes, for the reason
# iterm2_pane_alive gives: abandoning a live edit costs the user their text.
agterm_overlay_alive() {
  local out
  out=$(agterm_ctl session overlay result 2>&1) && return 1
  [[ "$out" != *"no overlay result"* && "$out" != *"overlay ended"* ]]
}

# Reads the reserved statuses and the launch-script writer the dispatcher
# defines; shellcheck lints a host standalone, since the dispatcher builds its
# path at run time and cannot be followed across.
# shellcheck disable=SC2154
review_host_run() {
  local cmd="$1" sentinel launch out rc=0

  sentinel=$(mktemp "${TMPDIR:-/tmp}/anchor-host-rc.XXXXXX")
  launch=$(mktemp "${TMPDIR:-/tmp}/anchor-host-launch.XXXXXX")

  anchor_host_launch_script "$cmd" > "$launch"
  chmod +x "$launch"

  # The overlay runs its command through `sh -c` on agterm's own PATH and
  # directory, which the launch script replaces with the caller's. Opened
  # without --block: agtermctl reports an overlay that could not open and a
  # command that exited 1 with the same status, and only the first means
  # nothing ran. `--follow` selects the calling session, so the overlay is in
  # front of the user rather than waiting on a session they have moved off.
  out=$(agterm_ctl session overlay open \
    "$(anchor_host_sq "$launch") $(anchor_host_sq "$sentinel")" \
    --size-percent 90 --follow 2>&1) || {
    echo "review-diff.sh: could not open an agterm overlay: $out" >&2
    rm -f "$sentinel" "$launch"
    return "$anchor_host_rc_no_pane"
  }

  rc=$(anchor_host_await "$sentinel" agterm_overlay_alive x) || rc=$?
  rm -f "$sentinel" "$launch"
  return "$rc"
}
