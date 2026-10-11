#!/usr/bin/env bash
# The skills that track tasks share one detection procedure, kept in
# guides/task-tracking.md, and each skill's section points at it.
#
# Claude Code withholds the task tools on models outside a fixed list, so a
# skill that opens by calling TaskList errors on load in those sessions (#101).
# The guide checks the tool listing first; this holds every skill to it, so a
# section copied from an older skill can't bring the unconditional call back.
# ci-platforms: linux macos

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
guide="$root/guides/task-tracking.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

skills=()
while IFS= read -r f; do
  skills+=("$f")
done < <(grep -l '^## Task tracking' "$root"/skills/*/SKILL.md | sort)
[[ ${#skills[@]} -gt 0 ]] || fail "no skill carries a task-tracking section"

section() {
  awk '/^## Task tracking/ { p = 1; print; next } p && /^## / { exit } p' "$1"
}

unlinked=()
unconditional=()
numbered=()
for f in "${skills[@]}"; do
  rel="${f#"$root"/}"
  body="$(section "$f")"
  grep -qF "\${CLAUDE_PLUGIN_ROOT}/guides/task-tracking.md" <<<"$body" || unlinked+=("$rel")
  grep -qiF "at the very start, call \`TaskList\`" <<<"$body" && unconditional+=("$rel")
  grep -qE '^ *(- )?`Step [0-9]+:' <<<"$body" && numbered+=("$rel")
done

[[ ${#unlinked[@]} -eq 0 ]] || fail "task-tracking section doesn't point at the guide: ${unlinked[*]}"
ok "every task-tracking section (${#skills[@]}) points at guides/task-tracking.md"

[[ ${#unconditional[@]} -eq 0 ]] || fail "calls TaskList before checking the tools exist: ${unconditional[*]}"
ok "no skill calls TaskList before checking the tool listing"

[[ ${#numbered[@]} -eq 0 ]] || fail "task names carry step numbers: ${numbered[*]}"
ok "no skill numbers its task names"

[[ -f "$guide" ]] || fail "guides/task-tracking.md is missing"

if ! grep -q 'TaskOutput' "$guide" || ! grep -q 'TaskStop' "$guide"; then
  fail "the guide doesn't rule out TaskOutput/TaskStop as evidence"
fi
ok "the guide rules out TaskOutput and TaskStop as evidence of the task list"

if ! grep -qi 'deferred' "$guide" || ! grep -q 'ToolSearch' "$guide"; then
  fail "the guide doesn't separate a deferred tool from an absent one"
fi
ok "the guide separates a deferred tool from an absent one"

echo "# all checks passed"
