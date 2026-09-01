#!/usr/bin/env bash
# What anchor knows about GUI editors that wait.
#
# Sourced, not executed, and it sources nothing itself — which is why it is its
# own file. Two callers need this knowledge from opposite ends of the dependency
# between the editor lib and the host dispatcher: the `gui` host is selected by
# it (scripts/review/hosts/gui.sh), and `edit` mode's `unsaved` failure names the
# flag that is missing (scripts/review/modes/edit.sh). Putting it in
# lib/review-editor.sh would have the host sourcing a file that sources the
# dispatcher currently selecting it.

# The flag this editor needs in order to wait, keyed on the command's own name —
# empty for an editor anchor does not know, which is a `core.editor` away rather
# than a guess (DIFF-16).
anchor_editor_wait_flag() {
  case "${1%% *}" in
    *code|*code-insiders) printf -- '--wait' ;;
    *subl|*mate)          printf -- '-w' ;;
    *bbedit)              printf -- '-W' ;;
    *gvim|*mvim)          printf -- '-f' ;;
  esac
}

# Does this editor's command line already say it waits? A flag anchor reads, a
# Windows `notepad` (which waits with no flag of its own), or the flag the table
# above names for an editor anchor knows.
anchor_editor_blocking() {
  local ed="${1:-}" flag
  [[ -n "$ed" ]] || return 1
  case "$ed" in
    notepad*|*"/notepad"*)       return 0 ;;
    *" --wait"*|*" -w"*|*" -W"*) return 0 ;;
  esac
  flag=$(anchor_editor_wait_flag "$ed")
  [[ -n "$flag" ]] && [[ "$ed" == *" $flag"* ]]
}
