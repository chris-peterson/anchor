#!/usr/bin/env bash
# SessionStart hook: emit this plugin's ambient rules into context.
# Stdout is added to context on every SessionStart source, including after
# compaction (no matcher in hooks.json). What gets injected and why:
# docs/ambient-rules.md (https://chris-peterson.github.io/anchor/#/ambient-rules).

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
RULES_DIR="$PLUGIN_ROOT/rules"
[ -d "$RULES_DIR" ] || exit 0

# Rules reference bundled files as ${CLAUDE_PLUGIN_ROOT}/<path> placeholders;
# expand them here so the injected text carries real, readable paths.
printf '# Ambient rules from the anchor plugin\n\n'
for f in "$RULES_DIR"/*.md; do
  [ -e "$f" ] || exit 0
  sed "s|\${CLAUDE_PLUGIN_ROOT}|$PLUGIN_ROOT|g" "$f"
  printf '\n'
done
