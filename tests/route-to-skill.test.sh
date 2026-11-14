#!/usr/bin/env bash
# Functional test for hooks/route-to-skill.sh, the PreToolUse guard on Bash.
#
# Feeds the hook the JSON Claude Code sends and asserts the decision: a raw
# release publish is denied with a reason that names /anchor:release and opens
# with its marker, and everything else — the skill's own script, read-only
# calls, a workflow that isn't a release, a command that only mentions one —
# passes with nothing printed. A false deny costs a session its next step and
# names a skill that can't do the job, so the passes are as load-bearing as the
# denies.
#
# The commands below are literal text for the hook to read, never expanded here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/../hooks/route-to-skill.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  echo "PASS"
  exit 0
fi

run() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook"
}

denies() {
  local out
  out=$(run "$1")
  [[ -n "$out" ]] || fail "expected a deny for: $1"
  [[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" == deny ]] \
    || fail "not a deny for: $1 -> $out"
  local reason
  reason=$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")
  [[ "$reason" == "[anchor:route-release]"* ]] || fail "reason lacks the marker: $reason"
  [[ "$reason" == *"/anchor:release"* ]] || fail "reason doesn't name the skill: $reason"
  [[ "$reason" == *"scripts/release-publish.sh"* ]] || fail "reason doesn't name the allowed route: $reason"
  ok "denies: $1"
}

passes() {
  local out
  out=$(run "$1")
  [[ -z "$out" ]] || fail "expected no output for: $1 -> $out"
  ok "passes: $1"
}

# --- denied: the commands a session reached for -------------------------------
denies 'gh workflow run .github/workflows/release.yml -f bump=minor'
denies 'gh workflow run release.yml -R acme/widget --ref main -f bump=minor'
denies 'cd /src/acme-widget; gh workflow run release.yml -f bump=patch'
denies 'cd /src/acme-widget && gh workflow run publish.yml -f level=major'
denies "gh workflow run publish.yml -f level='minor'"
denies 'for r in foo bar; do gh workflow run release.yml -R acme/$r -f bump=minor && echo "$r"; done'
denies 'gh release create v1.2.3 --notes-file /tmp/notes.md'
denies 'gh release create v1.2.3 --generate-notes'
denies 'glab release create v1.2.3 --notes-file /tmp/notes.md'
denies 'GH_HOST=github.com gh release create v1.2.3 -F notes.md'
denies 'out=$(gh release create v1.2.3 --notes-file n.md)'
denies 'gh api repos/acme/widget/releases -f tag_name=v1.2.3'
denies 'gh api -X POST repos/acme/widget/actions/workflows/release.yml/dispatches -f ref=main'
denies 'glab api --method POST projects/acme%2Fwidget/releases -f tag_name=v1.2.3'
denies $'git push origin main\ngh workflow run release.yml -f bump=minor'

# --- passed: the skill's route, reads, and the unrelated ----------------------
passes 'bash "/plugins/anchor/scripts/release-publish.sh" --dispatch .github/workflows/release.yml --input bump=minor'
passes 'bash "/plugins/anchor/scripts/release-publish.sh" --release v1.2.3 --notes-file /tmp/notes.md'
passes 'bash "/plugins/anchor/scripts/release-recon.sh"'
passes 'gh release view --json url,tagName'
passes 'glab release view -F json'
passes 'gh release list --limit 5'
passes 'gh run list --workflow release.yml --limit 1 --json databaseId,status,url'
passes 'gh workflow view release.yml --yaml'
passes 'gh workflow run deploy-docs.yml --ref main'
passes 'gh workflow run lint.yml -f target=docs'
passes 'gh api repos/acme/widget/releases/latest'
passes 'gh api repos/acme/widget/releases --jq ".[0].tag_name"'
passes 'grep -n "gh release create" guides/forge-cookbook.md'
passes 'rg "gh workflow run release.yml -f bump=minor" skills/'
passes 'git tag -a v1.2.3 -F notes.md'
passes 'ls -la'
passes ''

# Input it can't read fails open.
out=$(printf 'not json at all: release' | bash "$hook") || fail "hook exited non-zero on bad input"
[[ -z "$out" ]] || fail "bad input produced output: $out"
ok "fails open on unreadable input"

echo "PASS"
