#!/usr/bin/env bash
# Functional test for dev/codex-local.sh against a fake `codex` that keeps its
# installs and marketplaces in files, so pin and unpin are checked by the state
# they leave behind rather than by the commands they happened to run.
#
# The case with teeth is the round trip: whatever anchor was installed before
# pin is the one installed after unpin, from the marketplace it came from.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../dev/codex-local.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-codex-local-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/bin"
cat > "$work/bin/codex" <<'FAKE'
#!/usr/bin/env bash
# installs: one plugin id per line. markets: one marketplace name per line.
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_STATE/calls"
touch "$FAKE_STATE/installs" "$FAKE_STATE/markets"
case "$1 $2 ${3:-}" in
  "plugin list --json")
    jq -Rn '{installed: [inputs | select(length > 0) | {pluginId: ., name: (split("@")[0]), installed: true}]}' \
      < "$FAKE_STATE/installs" ;;
  "plugin marketplace list")
    jq -Rn '{marketplaces: [inputs | select(length > 0) | {name: .}]}' < "$FAKE_STATE/markets" ;;
  "plugin marketplace add")
    jq -r .name "$4/.agents/plugins/marketplace.json" >> "$FAKE_STATE/markets" ;;
  "plugin marketplace remove")
    grep -vx "$4" "$FAKE_STATE/markets" > "$FAKE_STATE/m.tmp" || true; mv "$FAKE_STATE/m.tmp" "$FAKE_STATE/markets" ;;
  "plugin marketplace upgrade") ;;
  "plugin add "*)
    echo "$3" >> "$FAKE_STATE/installs" ;;
  "plugin remove "*)
    grep -vx "$3" "$FAKE_STATE/installs" > "$FAKE_STATE/i.tmp" || true; mv "$FAKE_STATE/i.tmp" "$FAKE_STATE/installs" ;;
  *) echo "fake codex: unexpected $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$work/bin/codex"

export PATH="$work/bin:$PATH" CODEX_HOME="$work/codex" FAKE_STATE="$work/state"
mkdir -p "$CODEX_HOME" "$FAKE_STATE"
market="$CODEX_HOME/anchor-local-marketplace"

printf '%s\n' anchor@company-marketplace other@company-marketplace > "$FAKE_STATE/installs"
echo company-marketplace > "$FAKE_STATE/markets"

bash "$script" pin >/dev/null
[ "$(sort "$FAKE_STATE/installs" | tr '\n' ' ')" = "anchor@anchor-local other@company-marketplace " ] \
  || fail "pin should swap the released anchor for the local one and leave other plugins: $(cat "$FAKE_STATE/installs")"
[ -f "$market/plugins/anchor/.claude-plugin/plugin.json" ] || fail "the snapshot should hold the checkout's plugin"
[ ! -e "$market/plugins/anchor/.git" ]                     || fail "the snapshot should leave .git out"
ok "pin: the local snapshot replaces the installed anchor, other plugins untouched"

# Re-pinning after an edit: only the local anchor is installed by then, and the
# record of what to restore has to survive the snapshot being replaced.
bash "$script" pin >/dev/null
[ "$(cat "$market/.anchor-local-marketplace")" = "anchor@company-marketplace" ] \
  || fail "a second pin should keep the first pin's record, got: $(cat "$market/.anchor-local-marketplace")"
[ "$(grep -cx anchor-local "$FAKE_STATE/markets")" = 1 ] || fail "the local marketplace should be registered once"
ok "pin again: refreshes the snapshot and keeps what to restore"

bash "$script" unpin >/dev/null
[ "$(sort "$FAKE_STATE/installs" | tr '\n' ' ')" = "anchor@company-marketplace other@company-marketplace " ] \
  || fail "unpin should restore the anchor pin removed, from its own marketplace: $(cat "$FAKE_STATE/installs")"
grep -qx anchor-local "$FAKE_STATE/markets" && fail "unpin should unregister the local marketplace"
[ ! -e "$market" ] || fail "unpin should remove the snapshot"
ok "unpin: the anchor installed before pin comes back from the marketplace it came from"

bash "$script" unpin > "$work/out" || fail "unpin with nothing pinned should succeed"
grep -q 'nothing to undo' "$work/out" || fail "unpin with nothing pinned should say so: $(cat "$work/out")"
ok "unpin: with nothing pinned, does nothing and says so"

# A directory at the snapshot path that this script didn't make is never removed.
mkdir -p "$market" && touch "$market/keep"
rc=0; bash "$script" pin >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ -f "$market/keep" ] || fail "pin should refuse a directory it didn't create"
ok "pin: refuses to replace a directory it didn't create"
