#!/usr/bin/env bash
# Reads the plugin's version out of its manifest.
#
# Sourced, not executed. Two callers need the same answer from the same file —
# the CLI reporting `anchor --version` (CLI-07) and the freshness hook comparing
# the installed plugin against the wrapper on PATH (CLI-16) — and the hook's
# whole job is that comparison, so two parsers could disagree about one manifest.
#
# Parsed in the shell rather than with `jq`: the hook runs at every session
# start, on machines that have no jq, and a spawn there is charged to startup.
#
#   anchor_plugin_version "$PLUGIN_ROOT"   -> 1.5.0

anchor_plugin_version() {
  local manifest="$1/.claude-plugin/plugin.json" line value
  [ -r "$manifest" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"version"'*)
        value="${line#*\"version\"}"
        value="${value#*:}"
        value="${value#*\"}"
        value="${value%%\"*}"
        [ -n "$value" ] || return 1
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done < "$manifest"
  return 1
}
