#!/usr/bin/env bash
# Check the packaged instruction graph, including files moved out of SKILL.md.
# Codex rust-v0.155.1 ext/skills/src/render.rs caps injected prompts at 8,000
# UTF-8 bytes. Our 6,000-byte entry budget leaves room for future edits. Phase
# files are separate tool reads, not injections; bound them too for reliable reads.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$here/..}"
[[ $# -le 1 && -d "$root/skills" ]] || {
  echo "usage: check-skill-context.sh [plugin-root]" >&2
  exit 64
}

failed=0
count=0
fail() { echo "FAIL: $*" >&2; failed=1; }

check_size() {
  local path="$1" limit="$2" size
  size="$(wc -c < "$path" | tr -d '[:space:]')"
  if [[ "$size" -gt "$limit" ]]; then
    fail "${path#"$root"/}: $size bytes exceeds $limit"
  fi
}

for entry in "$root"/skills/*/SKILL.md; do
  [[ -f "$entry" ]] || continue
  count=$((count + 1))
  skill_dir="${entry%/SKILL.md}"
  check_size "$entry" 6000

  # Entry points link every required or conditional phase. This also makes
  # each phase reachable on the generated docs site.
  while IFS= read -r link; do
    path="${link#](}"
    path="${path%)}"
    [[ -f "$skill_dir/$path" ]] || fail "${entry#"$root"/}: missing $path"
  done < <(grep -oE '\]\(references/[A-Za-z0-9_./-]+\.md\)' "$entry" || true)

  if [[ -d "$skill_dir/references" ]]; then
    while IFS= read -r phase; do
      check_size "$phase" 8000
      relative="${phase#"$skill_dir"/}"
      grep -qF "]($relative)" "$entry" \
        || fail "${phase#"$root"/}: phase is not linked from SKILL.md"
    done < <(find "$skill_dir/references" -type f -name '*.md' | sort)
  fi
done

[[ "$count" -gt 0 ]] || fail "no skill entry points found"
[[ "$failed" -eq 0 ]] || exit 1
echo "ok - $count skill entry points fit the context budget; phase links and sizes checked"
