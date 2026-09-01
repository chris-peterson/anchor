#!/usr/bin/env bash
# tmux — a review host. Sourced by scripts/lib/review-host.sh once host selection
# settles; the contract these functions answer to is documented at the top of
# that file.
#
# A popup rather than a split pane: it borrows no layout of the user's and closes
# itself, where a pane has to be found again and closed. `display-popup -E`
# blocks until the command exits but reports its own status rather than the
# command's, so the status comes back through the sentinel the launch script
# writes.

review_host_available() {
  [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1
}

review_host_run() {
  local cmd="$1" sentinel launch rc=0
  sentinel=$(mktemp "${TMPDIR:-/tmp}/anchor-host-rc.XXXXXX")
  launch=$(mktemp "${TMPDIR:-/tmp}/anchor-host-launch.XXXXXX")

  anchor_host_launch_script "$cmd" > "$launch"
  chmod +x "$launch"

  # The paths reach the script as argv, so neither has to survive a second round
  # of quoting inside the popup's own shell.
  tmux display-popup -E -w 90% -h 90% \
    "$(anchor_host_sq "$launch") $(anchor_host_sq "$sentinel")" >/dev/null 2>&1 || true

  rc=$(anchor_host_read_rc "$sentinel") || rc=$?
  rm -f "$sentinel" "$launch"
  return "$rc"
}
