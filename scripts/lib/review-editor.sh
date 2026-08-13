#!/usr/bin/env bash
# Editor resolution and host selection for the `editor` review backend.
#
# Sourced, not executed. Two consumers need the same answers for different
# reasons, which is why this is a lib rather than private to the adapter:
#
#   scripts/review/editor.sh  opens the artifact, and needs the host to open it in
#   scripts/review-diff.sh    reports whether the editor route is offerable at all
#                             (--print-backend), without opening anything
#
# The dispatcher's probe question is not "is a binary on PATH" — the editor
# backend has no binary of its own. It is "would a launch reach an editor", and
# that takes both halves: an editor git can name, and somewhere to put it. A
# consumer that offers the editor route on the first half alone dead-ends the
# user in a `no-verdict` naming a host problem they were never warned about.

# Resolve the editor the way git does — core.editor, then VISUAL, then EDITOR,
# then git's own default. `git var GIT_EDITOR` answers that in one call, but it
# reads the GIT_EDITOR environment variable first, and an agent harness commonly
# exports `GIT_EDITOR=true` to keep git from ever opening one. Honoring that here
# would open nothing, change nothing, and read as "saved unchanged" — an
# approval the user never gave. So a no-op editor is treated as unset (DIFF-16).
anchor_editor_resolve() {
  local ed
  ed=$(git var GIT_EDITOR 2>/dev/null || true)
  case "$ed" in
    true|:|*/true) ed="" ;;
  esac
  [[ -n "$ed" ]] || ed=$(git config --get core.editor 2>/dev/null || true)
  [[ -n "$ed" ]] || ed="${VISUAL:-}"
  [[ -n "$ed" ]] || ed="${EDITOR:-}"
  printf '%s' "$ed"
}

# Name where the editor $1 can be put on screen, or nothing when there is
# nowhere. Claude Code's Bash tool has no controlling TTY, so a terminal editor
# can only render inside a terminal some host puts up. Ordered by how directly
# the host reports the editor's own exit status.
anchor_editor_host() {
  local ed="${1:-}"

  # An explicit launcher wins: the escape hatch for a host not handled below,
  # and the seam the tests drive.
  if [[ -n "${ANCHOR_EDITOR_LAUNCHER:-}" ]]; then printf 'launcher'; return; fi

  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then printf 'tmux'; return; fi

  # A GUI editor configured to block (`code --wait`, `subl -w`) needs no
  # terminal at all, and neither does a Windows `notepad`.
  if [[ "$ed" == *" --wait"* || "$ed" == *" -w"* || "$ed" == *" -W"* \
        || "$ed" == notepad* || "$ed" == *"/notepad"* ]]; then printf 'gui'; return; fi

  # A real TTY — anchor invoked from the user's own shell rather than an agent.
  if [[ -t 0 ]]; then printf 'tty'; return; fi

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] \
     && [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v osascript >/dev/null 2>&1; then
    printf 'iterm2'; return
  fi

  printf ''
}

# Would an editor review reach an editor: one resolves, and a host exists to
# open it in. An explicit launcher owns the editor choice, so it stands in for
# the config the same way the adapter treats it.
anchor_editor_available() {
  local ed
  ed=$(anchor_editor_resolve)
  [[ -n "$ed" || -n "${ANCHOR_EDITOR_LAUNCHER:-}" ]] || return 1
  [[ -n "$(anchor_editor_host "$ed")" ]]
}
