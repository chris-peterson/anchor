#!/usr/bin/env bash
# Editor resolution and host selection for the `editor` review backend.
#
# Sourced, not executed. Two consumers need the same answers for different
# reasons, which is why this is a lib rather than private to the adapter:
#
#   scripts/review/edit.sh    opens the artifact, and needs the host to open it in
#   scripts/review-diff.sh    resolves the editor as edit mode's backend and
#                             reports whether that route is offerable at all
#                             (--probe), without opening anything
#
# The dispatcher's probe question is not "is a binary on PATH" — edit mode has no
# binary of its own. It is "would a launch reach an editor", and
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

# The editor the user's own configuration names — anchor.edit.backend, then
# git's chain, GIT_EDITOR then core.editor then VISUAL then EDITOR, with the
# no-op scrub above in front of each rung. `git var GIT_EDITOR` answers git's half in one call, but it reads
# the environment variable first, so the rungs are walked by hand here. Empty
# when the user has configured nothing.
#
# Split out because two questions need it: which editor to open, and whether the
# user chose it — the launch names a config key only for one anchor picked.
anchor_editor_configured() {
  local ed
  # anchor's own key first: `edit` mode's tool half, the mirror of
  # anchor.diff.backend. Above git's chain because it is the narrower statement —
  # which editor to review in, not which to open for everything.
  ed=$(git config anchor.edit.backend 2>/dev/null || true)
  anchor_editor_usable "$ed" || ed=$(git var GIT_EDITOR 2>/dev/null || true)
  anchor_editor_usable "$ed" || ed=$(git config --get core.editor 2>/dev/null || true)
  anchor_editor_usable "$ed" || ed="${VISUAL:-}"
  anchor_editor_usable "$ed" || ed="${EDITOR:-}"
  anchor_editor_usable "$ed" || ed=""
  printf '%s' "$ed"
}

# git's compiled default — what a plain `git commit` opens here. It answers only
# with the environment's own editors out of the way entirely, since it honors an
# empty or no-op value as the answer rather than falling through, and each of
# them is walked and discounted above. TERM is pinned because git names no
# editor at all on a dumb terminal: that answers for the stdio git was handed,
# where this backend renders in a terminal the host opens (DIFF-17).
anchor_editor_compiled_default() {
  ( unset GIT_EDITOR VISUAL EDITOR; TERM=xterm git var GIT_EDITOR ) 2>/dev/null || true
}

# Does this session have somewhere to put a terminal — a tmux popup, the calling
# iTerm2 session's split, the user's own shell. Asked of the host selector with
# no editor named, so resolution and launch cannot disagree about it.
anchor_editor_terminal_host() {
  [[ -n "$(anchor_editor_host "")" ]]
}

# Resolve the editor to open: what the user configured, and past that two rungs
# of anchor's own, because git's chain runs out while this backend still has
# somewhere to go. An editor the user never configured is still an editor they
# have, and the alternative is refusing a review on a machine where `git commit`
# would have opened one.
#
# Which of the two rungs comes first turns on where anchor can draw. With a
# terminal to open, git's compiled default is both the editor a plain
# `git commit` opens here and the one that renders in the pane anchor labels and
# focuses (DIFF-25, DIFF-29, DIFF-30) rather than a window behind the terminal.
# With nowhere to put a terminal, a blocking GUI editor is the only rung that
# reaches anything at all. Both sit below every configured value, which is what
# keeps naming an editor a decision rather than a hint.
anchor_editor_resolve() {
  local ed candidate
  ed=$(anchor_editor_configured)
  if [[ -n "$ed" ]]; then printf '%s' "$ed"; return; fi

  if anchor_editor_terminal_host; then ed=$(anchor_editor_compiled_default); fi

  if ! anchor_editor_usable "$ed"; then
    ed=""
    for candidate in "${anchor_editor_candidates[@]}"; do
      if command -v "$candidate" >/dev/null 2>&1; then ed="$candidate --wait"; break; fi
    done
  fi

  # Nothing to host a terminal and no blocking GUI editor either. The compiled
  # default still names the editor, so the launch reports the host it cannot
  # find rather than an absent editor the user does have.
  anchor_editor_usable "$ed" || ed=$(anchor_editor_compiled_default)
  anchor_editor_usable "$ed" || ed=""
  printf '%s' "$ed"
}

# Where the resolved editor came from. The launch turns its configuration hint
# on this: a rung anchor picked is worth naming a key for, a value the user typed
# is not.
anchor_editor_source() {
  if [[ -n "$(anchor_editor_configured)" ]]; then printf 'config'; else printf 'default'; fi
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
