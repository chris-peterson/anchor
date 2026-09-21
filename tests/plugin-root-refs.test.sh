#!/usr/bin/env bash
# Every `<anchor-root>/<path>` a prompt tells the agent to read has to resolve to
# a file the plugin ships.
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
    rel="${ref#<anchor-root>/}"
    rel="${rel%%[.,;:\)\`\"]}"
    checked=$((checked + 1))
    if [[ ! -e "$root/$rel" ]]; then
      echo "  ${src#"$root"/} -> $rel" >&2
      missing=$((missing + 1))
    fi
  done < <(grep -ohE '<anchor-root>/[A-Za-z0-9_./-]+' "$src" || true)
done

[[ $checked -gt 0 ]] || fail "the scan matched no references at all — the pattern is broken"
[[ $missing -eq 0 ]] || fail "$missing plugin-root reference(s) point at a file the plugin doesn't ship"
ok "all $checked plugin-root references resolve to a shipped file"

for skill in "$root"/skills/*/SKILL.md; do
  grep -q '<anchor-root>/guides/host-runtime.md' "$skill" \
    || fail "${skill#"$root"/} does not establish the host runtime"
done
ok "every skill establishes the host-neutral runtime"

if grep -REn '\$\{CLAUDE_PLUGIN_ROOT\}|AskUserQuestion|BashOutput tool|run_in_background|Write tool|Read tool|TaskList' \
     "$root"/skills; then
  fail "skill instructions still depend on a Claude Code environment or tool name"
fi
ok "skill instructions carry no Claude Code runtime or tool-name dependency"

if grep -REn '/anchor:' "$root"/skills "$root"/rules; then
  fail "host-neutral skill and rule prose still prescribes Claude invocation syntax"
fi
ok "skill handoffs and ambient rules use host-neutral skill names"

command -v jq >/dev/null || { echo "SKIP: jq not installed; portable manifest not parsed"; exit 0; }
jq -e '
  ."$schema" == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
  and .name == "anchor"
  and .extensions."com.openai".hooks == "./hooks/hooks.json"
  and (.version | not)
' "$root/plugin.json" >/dev/null || fail "root plugin.json is not the portable Anchor manifest"
[[ -f "$root/.claude-plugin/plugin.json" ]] \
  || fail "portable packaging must not remove the Claude Code manifest"
ok "portable and Claude Code plugin manifests coexist"

grep -q '\${PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}' "$root/hooks/hooks.yml" \
  || fail "hook source does not accept both portable and Claude plugin roots"
ok "hook source accepts portable and Claude plugin roots"

portable_hook=$(env -u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT="$root" bash "$root/hooks/emit-rules.sh")
grep -q "Anchor plugin root: \`$root\`" <<<"$portable_hook" \
  || fail "portable hook invocation did not emit its resolved root"
grep -qF "$root/guides/forge-cookbook.md" <<<"$portable_hook" \
  || fail "portable hook invocation did not expand ambient-rule paths"

claude_hook=$(env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$root" bash "$root/hooks/emit-rules.sh")
grep -q "Anchor plugin root: \`$root\`" <<<"$claude_hook" \
  || fail "Claude hook invocation did not emit its resolved root"
ok "hook output resolves bundled paths under either host variable"

echo "# all checks passed"
