#!/usr/bin/env bash
# Every `${CLAUDE_PLUGIN_ROOT}/<path>` a prompt tells the agent to read has to
# resolve to a file the plugin ships.
#
# These paths are resolved at run time by the agent, not by a loader, so a
# retired or renamed file fails as a read error mid-flow rather than at install
# — and the skill that hit it carries on with the judgment that file was
# supposed to supply.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

# Prose sites where a reference is an instruction to read something. docs/ is
# shipyard's generated copy, so it is covered through its sources.
sources=()
while IFS= read -r f; do
  sources+=("$f")
done < <(
  find "$root/skills" "$root/guides" "$root/rules" "$root/templates" "$root/hooks" \
    -type f \( -name '*.md' -o -name '*.sh' \) | sort
)
[[ ${#sources[@]} -gt 0 ]] || fail "found no sources to scan"

missing=0
checked=0
for src in "${sources[@]}"; do
  # A path ends at the first character that can't be in one, so the trailing
  # punctuation of the sentence it sits in doesn't come along.
  while read -r ref; do
    rel="${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}"
    rel="${rel%%[.,;:\)\`\"]}"
    checked=$((checked + 1))
    if [[ ! -e "$root/$rel" ]]; then
      echo "  ${src#"$root"/} -> $rel" >&2
      missing=$((missing + 1))
    fi
  done < <(grep -ohE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$src" || true)
done

[[ $checked -gt 0 ]] || fail "the scan matched no references at all — the pattern is broken"
[[ $missing -eq 0 ]] || fail "$missing plugin-root reference(s) point at a file the plugin doesn't ship"
ok "all $checked plugin-root references resolve to a shipped file"

echo "# all checks passed"
