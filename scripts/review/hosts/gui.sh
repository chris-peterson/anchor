#!/usr/bin/env bash
# A blocking GUI editor — a review host for `edit` mode alone. Sourced by
# scripts/lib/review-host.sh; the contract these functions answer to is documented
# at the top of that file.
#
# The editor draws its own window, so there is no terminal to put up and nothing
# to carry into one: running it directly is both correct and the only path that
# works in a Git Bash session. What makes it a host at all is that it *blocks* —
# an editor that returns the moment it hands the file to an already-running
# instance reports a review the reviewer has not started.
#
# `diff` mode never lands here. A viewer's whole job is to render a changeset in
# a terminal, and no GUI editor stands in for one.

# Which flags mean "this editor waits" is shared with `edit` mode's unsaved
# failure, so it lives in its own leaf lib rather than here or in the editor lib
# that sources this dispatcher.
# shellcheck source=../../lib/editor-flags.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/editor-flags.sh"

review_host_available() {
  [[ "${1:-}" == "edit" ]] || return 1
  anchor_editor_blocking "${2:-}"
}

review_host_run() {
  local rc=0
  ( eval "$1" ) || rc=$?
  return "$rc"
}
