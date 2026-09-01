#!/usr/bin/env bash
# iTerm2 — a review host. Sourced by scripts/lib/review-host.sh; the contract
# these functions answer to is documented at the top of that file.
#
# A split of the calling session rather than a window: the review and the
# terminal that asked for it stay in one place, where a separate window can rest
# behind the one the user is watching, and a review silently waiting on them is
# indistinguishable from one that never opened.
#
# ITERM_SESSION_ID rather than TERM_PROGRAM: the command lands in a split of the
# *calling session*, so the host exists only where that session can be named,
# and iTerm2 is the only thing that names it.

review_host_available() {
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] || return 1
  [[ -n "${ITERM_SESSION_ID:-}" ]] || return 1
  command -v osascript >/dev/null 2>&1
}

# Is the pane $1 still on screen? "Cannot tell" answers yes: the question is
# only ever asked to decide whether to abandon a wait, and abandoning a live
# edit costs the user their text where waiting a little longer costs nothing.
iterm2_pane_alive() {
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

iterm2_pane_close() {
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

# Reads the reserved statuses and the launch-script writer the dispatcher
# defines; shellcheck lints a host standalone, since the dispatcher builds its
# path at run time and cannot be followed across.
# shellcheck disable=SC2154
review_host_run() {
  local cmd="$1" sentinel launch pane rc=0

  sentinel=$(mktemp "${TMPDIR:-/tmp}/anchor-host-rc.XXXXXX")
  launch=$(mktemp "${TMPDIR:-/tmp}/anchor-host-launch.XXXXXX")

  anchor_host_launch_script "$cmd" > "$launch"
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
    return "$anchor_host_rc_no_pane"
  }

  rc=$(anchor_host_await "$sentinel" iterm2_pane_alive "$pane") || rc=$?
  # Close the pane, so finishing returns the layout the review borrowed rather
  # than leaving a dead shell in the split.
  iterm2_pane_close "$pane"
  rm -f "$sentinel" "$launch"
  return "$rc"
}
