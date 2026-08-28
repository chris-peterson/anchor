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
# shellcheck source=split-run.sh
source "$(dirname "${BASH_SOURCE[0]}")/split-run.sh"

# A no-op editor is treated as unset (DIFF-16): an agent harness commonly exports
# `GIT_EDITOR=true` to keep git from ever opening one, and honoring that would
# open nothing, change nothing, and read as "saved unchanged" — an approval the
# user never gave. Applied to every rung below, since git's compiled default can
# be a no-op too on a purpose-built image.
anchor_editor_usable() {
  case "${1:-}" in
    ""|true|:|*/true) return 1 ;;
  esac
}

# The blocking GUI editors anchor reaches for when nothing is configured, most
# preferred first, each with the flag that makes it block — which is also what
# `anchor_editor_host` reads to pick the `gui` host. Kept to the editors that
# take `--wait`; anything else is a `core.editor` away (DIFF-16).
anchor_editor_candidates=(code code-insiders)

# Resolve the editor git would use — GIT_EDITOR, core.editor, VISUAL, EDITOR —
# and then two rungs of anchor's own, because git's chain runs out while this
# backend still has somewhere to go. `git var GIT_EDITOR` answers git's half in
# one call, but it reads the environment variable first, so the rungs are walked
# by hand here to keep the scrub above in front of each one.
#
# Past the user's configuration come a blocking VS Code and git's compiled
# default, in that order. `code --wait` renders through the `gui` host, which
# needs no terminal at all, where `vi` needs one some host puts up — so the
# reachable one goes first. Both sit below every configured value, which is what
# keeps naming an editor a decision rather than a hint.
anchor_editor_resolve() {
  local ed candidate
  ed=$(git var GIT_EDITOR 2>/dev/null || true)
  anchor_editor_usable "$ed" || ed=$(git config --get core.editor 2>/dev/null || true)
  anchor_editor_usable "$ed" || ed="${VISUAL:-}"
  anchor_editor_usable "$ed" || ed="${EDITOR:-}"
  if ! anchor_editor_usable "$ed"; then
    ed=""
    for candidate in "${anchor_editor_candidates[@]}"; do
      if command -v "$candidate" >/dev/null 2>&1; then ed="$candidate --wait"; break; fi
    done
  fi
  # git's compiled default — what a plain `git commit` opens here. It answers
  # only with the environment's own editors out of the way entirely, since it
  # honors an empty or no-op value as the answer rather than falling through,
  # and each of them was already walked and discounted above. TERM is pinned
  # because git names no editor at all on a dumb terminal: that answers for the
  # stdio git was handed, where this backend renders in a terminal the host
  # opens (DIFF-17).
  anchor_editor_usable "$ed" \
    || ed=$( (unset GIT_EDITOR VISUAL EDITOR; TERM=xterm git var GIT_EDITOR) 2>/dev/null || true)
  anchor_editor_usable "$ed" || ed=""
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

  # Asked of the runner that would do the opening, so the probe and the launch
  # cannot disagree about whether a split is reachable.
  if anchor_split_available; then printf 'iterm2'; return; fi

  printf ''
}

# Is there an editor to open at all, given the already-resolved editor $1: git
# named one, or an explicit launcher owns the choice and stands in for the
# config. Takes the resolved value so the probe below and the adapter — which
# has it in hand and must not disagree — ask the same question.
anchor_editor_named() {
  [[ -n "${1:-}" || -n "${ANCHOR_EDITOR_LAUNCHER:-}" ]]
}

# Would an editor review reach an editor: one is named, and a host exists to
# open it in.
anchor_editor_available() {
  local ed
  ed=$(anchor_editor_resolve)
  anchor_editor_named "$ed" || return 1
  [[ -n "$(anchor_editor_host "$ed")" ]]
}
