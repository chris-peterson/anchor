#!/usr/bin/env bash
# Put a command on screen where the user is already looking, and return its
# status.
#
# Sourced, not executed. Both review modes want the same thing — somewhere to
# render a program the reviewer reads and types into — so host selection lives
# here rather than once per mode. `edit` needs it for the editor it opens,
# `diff` for the viewer, and neither should reach further than the other.
#
# ## The host contract
#
# scripts/review/hosts/<name>.sh is sourced once selection settles and defines:
#
#   review_host_available <mode> <editor>
#                          can this host open here? `mode` is `edit` or `diff`,
#                          since a host may serve one and not the other;
#                          `editor` is the resolved editor in `edit` mode and
#                          empty in `diff`.
#   review_host_run <cmd>  run the `sh` command string, returning the command's
#                          own status — or one of the reserved statuses below,
#                          where the host never got it on screen.
#
# Hosts are ranked most direct first (`anchor_review_hosts`). One ranking serves
# both modes; a host that serves only one says so itself, in its own
# `review_host_available`.
#
# There is no host for the caller's own terminal, because a plugin has none:
# Claude Code runs these scripts through a tool call with no controlling TTY on
# every surface it ships. A host that could never be selected is a rung the
# fallback ladder has to reason about for nothing.

# Statuses a host reports for its own failures rather than the command's, kept
# apart so a caller can name the cause instead of quoting a status the command
# never produced. Each is printed on stderr as well; a command returning the
# same number is what that text disambiguates.
anchor_host_rc_no_result=124   # the host went away before the command reported
anchor_host_rc_no_pane=125     # the host could not be opened, so nothing ran

# Shell-quote one argument for the command string a host's `sh` reads.
anchor_host_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The hosts, most direct first. `gui` is a blocking editor's own window, so its
# own availability answers `edit` alone and `diff` passes over it.
anchor_review_hosts() {
  printf '%s\n' tmux gui iterm2
}

anchor_review_hosts_dir() {
  printf '%s' "$(dirname "${BASH_SOURCE[0]}")/../review/hosts"
}

# Select the host that would run a $1-mode review of an editor $2, leaving its
# name in `anchor_resolved_host` — empty where none can.
#
# Sourcing is the same act as asking: a host answers for itself, so the winner is
# the last file sourced and its `review_host_run` is the one left in scope. That
# is why the answer is *set* rather than printed — a `$(...)` call would run this
# in a subshell and drop the source along with it, leaving `anchor_host_run`
# with a host name and no runner to go with it.
anchor_resolved_host=""
anchor_review_host_select() {
  local mode="${1:-diff}" editor="${2:-}" host file
  anchor_resolved_host=""
  [[ -z "${ANCHOR_HOST_RUNNER:-}" ]] || { anchor_resolved_host=launcher; return; }
  while IFS= read -r host; do
    file="$(anchor_review_hosts_dir)/${host}.sh"
    [[ -r "$file" ]] || continue
    # shellcheck source=/dev/null
    source "$file"
    if review_host_available "$mode" "$editor"; then anchor_resolved_host="$host"; return; fi
  done < <(anchor_review_hosts)
}

# The same question for a caller that wants only the name — the probe, and
# `edit`'s own host report. Safe in a subshell precisely because the runner it
# leaves behind is not what the caller is after.
anchor_review_host() {
  anchor_review_host_select "${1:-diff}" "${2:-}"
  printf '%s' "$anchor_resolved_host"
}

# Is there anywhere to open a $1-mode review of an editor $2 at all?
anchor_host_available() {
  [[ -n "$(anchor_review_host "${1:-diff}" "${2:-}")" ]]
}

# Block until the command reports its status, then return it. For a host that
# does not block on the command itself and can be asked whether it is still on
# screen: $2 is a predicate taking $3.
#
# There is no time cap. The person on the other end is reading and typing, and a
# cap generous enough never to interrupt them is also too long to be a useful
# guard — what it reliably does instead is discard a draft mid-edit. The signal
# that actually means "no result is coming" is the host going away without
# writing, which is what ends the wait early. Checking that costs a round trip,
# so the sentinel is read every second and the host every fifteenth.
anchor_host_await() {
  local sentinel="$1" alive="$2" arg="$3" ticks=0
  while [[ ! -s "$sentinel" ]]; do
    sleep 1
    ticks=$((ticks + 1))
    if [[ $((ticks % 15)) -eq 0 ]] && ! "$alive" "$arg"; then
      echo "review-diff.sh: the review closed without reporting a result" >&2
      return "$anchor_host_rc_no_result"
    fi
  done
  cat "$sentinel"
}

# Read the status a launch script left behind, for a host that has already
# blocked on the command. The write lands a moment after the command exits, so a
# short grace covers the gap; still empty past it, the host went away and no
# result is coming. This is not a cap on the review — the host blocked for as
# long as that took — only on the write that follows it.
anchor_host_read_rc() {
  local sentinel="$1" waited=0
  while [[ ! -s "$sentinel" ]]; do
    [[ "$waited" -lt 5 ]] || {
      echo "review-diff.sh: the review closed without reporting a result" >&2
      return "$anchor_host_rc_no_result"
    }
    sleep 1
    waited=$((waited + 1))
  done
  cat "$sentinel"
}

# Write the `/bin/sh` script a host runs: the caller's context, then the command
# string $1, then the command's status to the sentinel path the script takes as
# its own argument.
#
# A host that puts up a new terminal does not run its command through a login
# shell, and starts it in the terminal application's own environment and
# whatever directory that inherits. Everything in the command was resolved
# against the caller's, so the new terminal has to run in the caller's:
#   * the working directory, because a review is asked for as git refs, which
#     name commits only in the repo the dispatcher resolved them against — a
#     terminal standing anywhere else renders that other repo's diff, or an
#     empty one.
#   * PATH, to find the binary at all: iTerm2's own is `/usr/bin:/bin:…` and
#     nothing a profile added, so a lookup over there reports "not found" for a
#     tool that is plainly installed and the terminal dies on 127 before drawing.
#   * the locale, because these artifacts are markdown a TUI has to render.
#   * EDITOR/VISUAL, because a viewer opens an editor of its own for a
#     multi-line annotation.
anchor_host_launch_script() {
  local cmd="$1" name value
  printf '#!/bin/sh\n'
  printf 'cd %s || exit 1\n' "$(anchor_host_sq "$PWD")"
  printf 'export PATH=%s\n' "$(anchor_host_sq "$PATH")"
  for name in LANG LC_ALL EDITOR VISUAL; do
    value="${!name:-}"
    [[ -z "$value" ]] || printf 'export %s=%s\n' "$name" "$(anchor_host_sq "$value")"
  done
  printf '%s\n' "$cmd"
  printf 'rc=$?; printf %%s "$rc" > "$1.tmp" && mv -f "$1.tmp" "$1"\n'
}

# Run the `sh` command string $1 in the best host for a $2-mode review of an
# editor $3, and return the command's own status.
anchor_host_run() {
  local cmd="$1" mode="${2:-diff}" editor="${3:-}" rc=0

  # The seam the tests drive, and the escape hatch for a host anchor does not
  # ship: a program taking the command string and returning its status.
  if [[ -n "${ANCHOR_HOST_RUNNER:-}" ]]; then
    "$ANCHOR_HOST_RUNNER" "$cmd" || rc=$?
    return "$rc"
  fi

  anchor_review_host_select "$mode" "$editor"
  if [[ -z "$anchor_resolved_host" ]]; then
    echo "review-diff.sh: nowhere to open a review — not inside tmux, and no iTerm2 session to split" >&2
    return "$anchor_host_rc_no_pane"
  fi
  # Selection sourced the winner, so its review_host_run is in scope.
  review_host_run "$cmd" || rc=$?
  return "$rc"
}
