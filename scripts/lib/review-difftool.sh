#!/usr/bin/env bash
# Whether git can launch a name as a difftool, and what the user configured as
# theirs.
#
# Sourced, not executed. Two callers need the same answers and neither can ask
# the other: the dispatcher resolves `diff` mode's backend and reports whether it
# can open (`--probe`), and scripts/review/diff.sh has to pick an adapter for the
# name before it sources one.
#
# A difftool is not a PATH question. A name can be one git ships a recipe for
# (`vimdiff`, `opendiff`) or one the user wrote a `difftool.<name>.cmd` for, and
# neither has to be a binary of that name.

# The user's own choice, or empty. `diff.tool` is what `git difftool` reads, so
# honoring it is what makes a review open in the tool they already picked.
anchor_difftool_configured() {
  git config --get diff.tool 2>/dev/null || true
}

# Can git launch $1? `--tool-help` lists what is reachable here above the
# "valid, but not currently available" line, and a configured `cmd` answers for
# itself without appearing in either list.
anchor_difftool_known() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ -z "$(git config "difftool.${name}.cmd" 2>/dev/null || true)" ]] || return 0
  git difftool --tool-help 2>/dev/null \
    | sed -n '1,/valid, but not currently available/p' \
    | grep -qE "^[[:space:]]+${name}([[:space:]]|\$)"
}
