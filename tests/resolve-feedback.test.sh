#!/usr/bin/env bash
# resolve-feedback infers the CR from the branch, and neither CLI filters that
# lookup by state: on a reused branch name `gh pr view` / `glab mr view` answer
# with the merged or closed CR that used the name last, exit 0. A lookup that
# projects no state cannot tell that CR from an open one, so the skill would
# work feedback on a CR that has already landed (FEEDBACK-02). This holds the
# skill's lookup to reading the state on both forges, and to the same open
# values prepare-review.sh's resolve_cr accepts (PREPARE-03a).
# ci-platforms: linux macos

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
skill="$root/skills/resolve-feedback/SKILL.md"
prepare="$root/scripts/prepare-review.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

[[ -f "$skill" ]] || fail "skills/resolve-feedback/SKILL.md is missing"

section="$(awk '/^## Target repo and CR/ { p = 1; print; next } p && /^## / { exit } p' "$skill")"
[[ -n "$section" ]] || fail "the skill has no 'Target repo and CR' section"

glab_lookup="$(grep -E '^glab mr view --output json' <<<"$section" || true)"
gh_lookup="$(grep -E '^gh pr view --json' <<<"$section" || true)"
[[ -n "$glab_lookup" ]] || fail "no glab branch lookup in 'Target repo and CR'"
[[ -n "$gh_lookup" ]] || fail "no gh branch lookup in 'Target repo and CR'"

grep -qE "jq '\{[^}]*\bstate\b[^}]*\}'" <<<"$glab_lookup" \
  || fail "the GitLab lookup projects no state: $glab_lookup"
ok "the GitLab branch lookup reads the MR's state"

grep -qE -- '--json [^ ]*\bstate\b' <<<"$gh_lookup" \
  || fail "the GitHub lookup requests no state: $gh_lookup"
ok "the GitHub branch lookup reads the PR's state"

grep -q '!= "opened"' "$prepare" || fail "prepare-review.sh no longer compares the MR state to \"opened\""
grep -q '!= "OPEN"' "$prepare" || fail "prepare-review.sh no longer compares the PR state to \"OPEN\""
grep -qF "\`opened\`" <<<"$section" || fail "the skill doesn't name opened as GitLab's open state"
grep -qF "\`OPEN\`" <<<"$section" || fail "the skill doesn't name OPEN as GitHub's open state"
ok "the skill's open states match prepare-review.sh resolve_cr"

echo "# all checks passed"
