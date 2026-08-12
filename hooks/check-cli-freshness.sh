#!/usr/bin/env bash
# SessionStart hook: report an `anchor` wrapper left behind by a plugin update.
#
# `anchor install-cli` writes the wrapper with the plugin path it was generated
# from baked in, so a plugin update leaves it running the previous build. Nothing
# else notices — the slash command and the skills resolve CLAUDE_PLUGIN_ROOT and
# stay current, while a plain shell keeps the stale CLI. Comparing the two
# versions once per session catches it for every consumer rather than only for
# whoever happens to invoke a skill that checks.
#
# Never blocks, and stays silent when `anchor` is not on PATH: the plugin works
# without the wrapper, so its absence is not drift.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] || exit 0

command -v anchor >/dev/null 2>&1 || exit 0

# shellcheck source=../scripts/lib/plugin-version.sh
source "$PLUGIN_ROOT/scripts/lib/plugin-version.sh"

plugin_version=$(anchor_plugin_version "$PLUGIN_ROOT") || plugin_version=""
[ -n "$plugin_version" ] || exit 0

# `anchor --version` prints "anchor <version>". CLAUDE_PLUGIN_ROOT is cleared for
# that one call on purpose: the CLI prefers it over its own location (CLI-02), so
# an inherited one makes the old build read the *current* manifest and report a
# version that always matches — the comparison below could never come out
# unequal. Cleared, the wrapper resolves from the path it baked in, which is the
# build it actually runs.
#
# A wrapper that cannot report a version is not drift this hook can prove, so
# swallow the failure rather than letting pipefail surface it as a hook error on
# every session start.
wrapper_out=$(CLAUDE_PLUGIN_ROOT='' anchor --version 2>/dev/null) || wrapper_out=""
case "${wrapper_out%%$'\n'*}" in
  "anchor "*) wrapper_version="${wrapper_out#anchor }" ;;
  *)          exit 0 ;;
esac
wrapper_version="${wrapper_version%%$'\n'*}"
[ -n "$wrapper_version" ] || exit 0

if [ "$wrapper_version" = "$plugin_version" ]; then
  exit 0
fi

# The backticks are markdown code spans in the injected text, not substitution.
# shellcheck disable=SC2016
printf 'The `anchor` CLI on PATH reports version %s, but the installed anchor plugin is %s. The wrapper at that path was written by a past `install-cli` and points at where the plugin lived then, so it is running the old build. Tell the user to run `/anchor:anchor install-cli` to refresh it; the skills and the slash command are unaffected.\n' \
  "$wrapper_version" "$plugin_version"
