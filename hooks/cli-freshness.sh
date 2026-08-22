#!/usr/bin/env bash
# SessionStart hook: report a PATH wrapper left behind by a plugin update.
#
# `install-cli` writes the wrapper with the plugin path it was generated from
# baked in, and plugin directories are version-pinned, so an update leaves the
# wrapper running the previous build. Nothing else notices: the slash command
# and the skills resolve CLAUDE_PLUGIN_ROOT and stay current, while a plain
# shell keeps the stale CLI. Comparing the two versions once per session catches
# it for every consumer rather than only for whoever invokes a skill that checks.
#
# Never blocks, and stays silent when the CLI is not on PATH: the plugin works
# without the wrapper, so its absence is not drift.

set -euo pipefail

NAME="anchor"
REFRESH_COMMAND="/anchor:anchor install-cli"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] || exit 0
command -v "$NAME" >/dev/null 2>&1 || exit 0

# CLI-07: the CLI and this hook read the manifest through one parser, so the two
# sides of the comparison below cannot disagree about the same file.
# shellcheck source=../scripts/lib/plugin-version.sh
source "$PLUGIN_ROOT/scripts/lib/plugin-version.sh"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

plugin_ver=$(anchor_plugin_version "$PLUGIN_ROOT") || exit 0

# CLAUDE_PLUGIN_ROOT is cleared for this one call on purpose: the CLI prefers it
# over its own location (CLI-02), so an inherited one makes the old build read
# the *current* manifest and report a version that always matches — the
# comparison below could never come out unequal. Cleared, the wrapper resolves
# from the path it baked in, which is the build it actually runs.
#
# A wrapper that cannot report a version is not drift this hook can prove, so
# swallow the failure rather than letting pipefail surface it as a hook error on
# every session start.
wrapper_out=$(env -u CLAUDE_PLUGIN_ROOT "$NAME" --version 2>/dev/null) || wrapper_out=""
case "${wrapper_out%%$'\n'*}" in
  "$NAME "*) wrapper_ver="${wrapper_out#"$NAME "}" ;;
  *)         exit 0 ;;
esac
wrapper_ver="${wrapper_ver%%$'\n'*}"
[ -n "$wrapper_ver" ] || exit 0

[ "$wrapper_ver" = "$plugin_ver" ] && exit 0

msg="PLEASE TELL THE USER (do not skip): the $NAME CLI on PATH reports version $wrapper_ver, but the installed $NAME plugin is $plugin_ver. The wrapper was written by a past install and points at where the plugin lived then, so a plain shell runs the old build. Run $REFRESH_COMMAND to refresh it, or \`git pull\` in the local source checkout if the wrapper points there. Running the bootstrap from a shell will not fix it: the stale wrapper re-installs itself from the version it already names. Skills and slash commands are unaffected."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(json_escape "$msg")"
