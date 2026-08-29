#!/usr/bin/env bash
# Run a command in a split of the calling iTerm2 session.
#
# Sourced, not executed. Both review backends want the same thing — a terminal
# for a TUI, opened where the user is already looking — so the split lives here
# rather than twice in the adapters.
#
# A split rather than a window: the review and the terminal that asked for it
# stay in one place, where a separate window can rest behind the one the user is
# watching, and a review silently waiting on them is indistinguishable from one
# that never opened.

# Shell-quote one argument for the command string the pane's `sh` reads.
anchor_split_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Can a split be opened here? ITERM_SESSION_ID rather than TERM_PROGRAM: the
# command lands in a split of the *calling session*, so the host exists only
# where that session can be named, and iTerm2 is the only thing that names it.
anchor_split_available() {
  [[ -n "${ANCHOR_SPLIT_RUNNER:-}" ]] && return 0
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] || return 1
  [[ -n "${ITERM_SESSION_ID:-}" ]] || return 1
  command -v osascript >/dev/null 2>&1
}

# Is the pane $1 still on screen? "Cannot tell" answers yes: the question is
# only ever asked to decide whether to abandon a wait, and abandoning a live
# edit costs the user their text where waiting a little longer costs nothing.
anchor_split_alive() {
  local found
  found=$(osascript - "$1" 2>/dev/null <<'APPLESCRIPT'
on run argv
    set sid to item 1 of argv
    tell application id "com.googlecode.iterm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if id of s is sid then return "yes"
                end repeat
            end repeat
        end repeat
    end tell
    return "no"
end run
APPLESCRIPT
  ) || return 0
  [[ "$found" == "yes" ]]
}

# Block until the pane reports its status, then return it.
#
# There is no time cap. The person on the other end is reading and typing, and a
# cap generous enough never to interrupt them is also too long to be a useful
# guard — what it reliably does instead is discard a draft mid-edit. The signal
# that actually means "no result is coming" is the pane going away without
# writing, which is what ends the wait early. Checking that costs an osascript
# round trip, so the sentinel is read every second and the pane every fifteenth.
anchor_split_await() {
  local sentinel="$1" pane="$2" ticks=0
  while [[ ! -s "$sentinel" ]]; do
    sleep 1
    ticks=$((ticks + 1))
    if [[ $((ticks % 15)) -eq 0 ]] && ! anchor_split_alive "$pane"; then
      echo "review-diff.sh: the review pane closed without reporting a result" >&2
      return 125
    fi
  done
  cat "$sentinel"
}

anchor_split_close() {
  osascript - "$1" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
    set sid to item 1 of argv
    tell application id "com.googlecode.iterm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if id of s is sid then
                        tell s to close
                        return
                    end if
                end repeat
            end repeat
        end repeat
    end tell
end run
APPLESCRIPT
}

# Write the `/bin/sh` script the pane runs: the caller's context, then the
# command string $1, then the command's status to the sentinel path the script
# takes as its own argument.
#
# iTerm2 runs a split's command directly rather than through a login shell, and
# starts it in the terminal's own environment and whatever directory that
# inherits. Everything in the command was resolved against the caller's, so the
# pane has to run in the caller's:
#   * the working directory, because a review is asked for as git refs, which
#     name commits only in the repo the dispatcher resolved them against — a pane
#     standing anywhere else renders that other repo's diff, or an empty one.
#   * PATH, to find the binary at all: iTerm2's own is `/usr/bin:/bin:…` and
#     nothing a profile added, so a lookup over there reports "not found" for a
#     tool that is plainly installed and the pane dies on 127 before drawing.
#   * the locale, because these artifacts are markdown a TUI has to render.
#   * EDITOR/VISUAL, because revdiff opens an editor of its own for a multi-line
#     annotation.
anchor_split_launch_script() {
  local cmd="$1" name value
  printf '#!/bin/sh\n'
  printf 'cd %s || exit 1\n' "$(anchor_split_sq "$PWD")"
  printf 'export PATH=%s\n' "$(anchor_split_sq "$PATH")"
  for name in LANG LC_ALL EDITOR VISUAL; do
    value="${!name:-}"
    [[ -z "$value" ]] || printf 'export %s=%s\n' "$name" "$(anchor_split_sq "$value")"
  done
  printf '%s\n' "$cmd"
  printf 'rc=$?; printf %%s "$rc" > "$1.tmp" && mv -f "$1.tmp" "$1"\n'
}

# Run the `sh` command string $1 in a split, and return the command's own status.
anchor_split_run() {
  local cmd="$1" sentinel launch pane rc=0

  # The seam the tests drive, and the escape hatch for a host this doesn't
  # handle: a program taking the command string and returning its status.
  if [[ -n "${ANCHOR_SPLIT_RUNNER:-}" ]]; then
    "$ANCHOR_SPLIT_RUNNER" "$cmd" || rc=$?
    return "$rc"
  fi

  sentinel=$(mktemp "${TMPDIR:-/tmp}/anchor-split-rc.XXXXXX")
  launch=$(mktemp "${TMPDIR:-/tmp}/anchor-split-launch.XXXXXX")

  anchor_split_launch_script "$cmd" > "$launch"
  chmod +x "$launch"

  # ITERM_SESSION_ID is "w0t0p0:UUID"; AppleScript's session id is the UUID.
  # The paths reach it as argv and the pane runs a script, so neither has to
  # survive a second round of quoting.
  #
  # A split opened this way is created but not selected: the tab keeps the
  # calling session current, so the review renders beside a terminal that goes
  # on taking the keystrokes meant for it. `select` hands the pane the keyboard
  # the review is read and annotated with.
  #
  # iTerm2 then draws the tab from whichever session holds that focus, and the
  # new one carries none of the session variables a title format reads, so the
  # tab label would empty for the length of the review. Copying the caller's
  # rendered name onto the pane keeps the label the user was reading, and the 👀
  # leading it says which of their windows is waiting on them to read something.
  # The mark lives in the name because that is a session's own string: a pane
  # background would need a profile to carry it, where this needs nothing. The
  # copy is attempted, not required: the pane is already running the review by
  # the time it happens, and an error there would be reported as a split that
  # never opened.
  pane=$(osascript - "${ITERM_SESSION_ID##*:}" "$launch" "$sentinel" <<'APPLESCRIPT' 2>&1
on run argv
    set targetId to item 1 of argv
    set cmd to quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv)
    tell application id "com.googlecode.iterm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if id of s is targetId then
                        set paneName to name of s
                        tell s
                            if (columns of s) >= 160 and (columns of s) > ((rows of s) * 2) then
                                set newSession to split vertically with same profile command cmd
                            else
                                set newSession to split horizontally with same profile command cmd
                            end if
                        end tell
                        try
                            set name of newSession to "👀 " & paneName
                        end try
                        select newSession
                        return id of newSession
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    error "session not found: " & targetId
end run
APPLESCRIPT
  ) || {
    # No pane means the command never ran, so say so instead of waiting on a
    # sentinel nothing will write.
    echo "review-diff.sh: could not split the iTerm2 session: $pane" >&2
    rm -f "$sentinel" "$launch"
    return 125
  }

  rc=$(anchor_split_await "$sentinel" "$pane") || rc=$?
  # Close the pane, so finishing returns the layout the review borrowed rather
  # than leaving a dead shell in the split.
  anchor_split_close "$pane"
  rm -f "$sentinel" "$launch"
  return "$rc"
}
