#!/usr/bin/env bash
# The developer pinning scripts swap both hosts without touching real settings.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
pin="$root/dev/pin-local.sh"
unpin="$root/dev/unpin-local.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-dev-pin-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

cat > "$bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'claude %s\n' "$*" >> "$CALL_LOG"

case "$*" in
  "plugin list --json")
    if [[ "${FAKE_PHASE:-pin}" == pin ]]; then
      printf '%s\n' \
        '  {"id": "anchor@getty-claude-marketplace"},' \
        '  {"id": "other@example"}'
    else
      printf '%s\n' \
        '  {"id": "anchor@chris-peterson"},' \
        '  {"id": "anchor@getty-claude-marketplace"},' \
        '  {"id": "anchor@skills-dir"}'
    fi
    ;;
  "plugin marketplace list --json")
    printf '%s\n' '  {"name": "chris-peterson"}'
    ;;
esac
FAKE

cat > "$bin/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex %s\n' "$*" >> "$CALL_LOG"

case "$*" in
  "plugin list --json")
    if [[ "${FAKE_PHASE:-pin}" == pin ]]; then
      printf '%s\n' \
        '  {"pluginId": "anchor@getty-claude-marketplace"},' \
        '  {"pluginId": "anchor@anchor-local"}'
    else
      printf '%s\n' \
        '  {"pluginId": "anchor@chris-peterson"},' \
        '  {"pluginId": "anchor@getty-claude-marketplace"},' \
        '  {"pluginId": "anchor@anchor-local"}'
    fi
    ;;
  "plugin marketplace list --json")
    printf '%s\n' \
      '  {"name": "chris-peterson"},' \
      '  {"name": "anchor-local"}'
    ;;
esac
FAKE

chmod +x "$bin/claude" "$bin/codex"

export PATH="$bin:/usr/bin:/bin"
export CALL_LOG="$work/calls.log"
export CLAUDE_CONFIG_DIR="$work/claude"
export CODEX_HOME="$work/codex"

FAKE_PHASE=pin bash "$pin" > "$work/pin.out"

[[ -L "$CLAUDE_CONFIG_DIR/skills/anchor" ]] \
  || fail "pin did not create the Claude skills-directory symlink"
[[ "$(readlink "$CLAUDE_CONFIG_DIR/skills/anchor")" == "$root" ]] \
  || fail "Claude symlink does not point at this checkout"
grep -q 'claude plugin uninstall --scope user --keep-data anchor@getty-claude-marketplace' "$CALL_LOG" \
  || fail "pin did not remove the installed Claude marketplace copy"
ok "Claude Code loads this checkout in place and removes the released copy"

codex_market="$CODEX_HOME/anchor-local-marketplace"
[[ -f "$codex_market/plugins/anchor/plugin.json" ]] \
  || fail "pin did not snapshot the portable plugin for Codex"
[[ -f "$codex_market/.anchor-local-marketplace" ]] \
  || fail "pin did not mark the generated Codex marketplace as script-owned"
[[ ! -e "$codex_market/plugins/anchor/.git" ]] \
  || fail "Codex snapshot copied the checkout's .git directory"
grep -q '"name": "anchor-local"' "$codex_market/.agents/plugins/marketplace.json" \
  || fail "Codex marketplace has the wrong identity"
grep -q "codex plugin marketplace add $codex_market" "$CALL_LOG" \
  || fail "pin did not register the local Codex marketplace"
grep -q 'codex plugin add anchor@anchor-local' "$CALL_LOG" \
  || fail "pin did not install the local Codex plugin"
ok "Codex installs a checkout snapshot through a local marketplace"

: > "$CALL_LOG"
FAKE_PHASE=unpin bash "$unpin" > "$work/unpin.out"

[[ ! -e "$CLAUDE_CONFIG_DIR/skills/anchor" && ! -L "$CLAUDE_CONFIG_DIR/skills/anchor" ]] \
  || fail "unpin left the Claude local-plugin symlink behind"
grep -q 'claude plugin marketplace update chris-peterson' "$CALL_LOG" \
  || fail "unpin did not refresh the canonical Claude marketplace"
grep -q 'claude plugin install --scope user anchor@chris-peterson' "$CALL_LOG" \
  || fail "unpin did not reinstall canonical Anchor for Claude"
ok "Claude Code returns to the latest canonical marketplace copy"

[[ ! -e "$codex_market" && ! -L "$codex_market" ]] \
  || fail "unpin left the generated Codex marketplace behind"
grep -q 'codex plugin marketplace upgrade chris-peterson' "$CALL_LOG" \
  || fail "unpin did not refresh the canonical Codex marketplace"
grep -q 'codex plugin add anchor@chris-peterson' "$CALL_LOG" \
  || fail "unpin did not reinstall canonical Anchor for Codex"
grep -q 'codex plugin marketplace remove anchor-local' "$CALL_LOG" \
  || fail "unpin did not unregister the local Codex marketplace"
ok "Codex returns to the latest canonical marketplace copy"

collision="$work/collision"
mkdir -p "$collision/skills/anchor"
: > "$CALL_LOG"
if CLAUDE_CONFIG_DIR="$collision" FAKE_PHASE=pin bash "$pin" > /dev/null 2>&1; then
  fail "pin replaced a non-symlink Claude skills directory"
fi
[[ ! -s "$CALL_LOG" ]] || fail "pin changed host state before refusing the collision"
ok "an existing non-symlink Claude plugin path is left untouched"

other_checkout="$work/other-anchor"
mkdir -p "$other_checkout"
other_config="$work/other-config"
mkdir -p "$other_config/skills"
ln -s "$other_checkout" "$other_config/skills/anchor"
: > "$CALL_LOG"
if CLAUDE_CONFIG_DIR="$other_config" FAKE_PHASE=pin bash "$pin" > /dev/null 2>&1; then
  fail "pin replaced a symlink to another checkout"
fi
[[ "$(readlink "$other_config/skills/anchor")" == "$other_checkout" ]] \
  || fail "pin changed the foreign Claude plugin symlink"
[[ ! -s "$CALL_LOG" ]] || fail "pin changed host state before refusing the foreign symlink"
ok "a Claude symlink to another checkout is left untouched"

codex_collision="$work/codex-collision"
mkdir -p "$codex_collision/anchor-local-marketplace"
: > "$CALL_LOG"
if CLAUDE_CONFIG_DIR="$work/collision-free-claude" \
   CODEX_HOME="$codex_collision" \
   FAKE_PHASE=pin bash "$pin" > /dev/null 2>&1; then
  fail "pin replaced an unrecognized Codex marketplace directory"
fi
[[ -d "$codex_collision/anchor-local-marketplace" ]] \
  || fail "pin removed the unrecognized Codex marketplace directory"
[[ ! -s "$CALL_LOG" ]] || fail "pin changed host state before refusing the Codex collision"
ok "an unrecognized Codex marketplace directory is left untouched"

# --- One installed host never touches the absent host's directories ---------
claude_only_bin="$work/claude-only-bin"
mkdir -p "$claude_only_bin"
ln -s "$bin/claude" "$claude_only_bin/claude"
claude_only_config="$work/claude-only-config"
claude_only_codex="$work/claude-only-codex"
: > "$CALL_LOG"
PATH="$claude_only_bin:/usr/bin:/bin" \
CLAUDE_CONFIG_DIR="$claude_only_config" \
CODEX_HOME="$claude_only_codex" \
FAKE_PHASE=pin bash "$pin" > "$work/claude-only-pin.out"
[[ -L "$claude_only_config/skills/anchor" ]] \
  || fail "Claude-only pin did not install the local Claude plugin"
[[ ! -e "$claude_only_codex" ]] \
  || fail "Claude-only pin created the absent Codex host's directory"
if grep -q '^codex ' "$CALL_LOG"; then
  fail "Claude-only pin invoked Codex"
fi

: > "$CALL_LOG"
PATH="$claude_only_bin:/usr/bin:/bin" \
CLAUDE_CONFIG_DIR="$claude_only_config" \
CODEX_HOME="$claude_only_codex" \
FAKE_PHASE=unpin bash "$unpin" > "$work/claude-only-unpin.out"
[[ ! -e "$claude_only_config/skills/anchor" && ! -L "$claude_only_config/skills/anchor" ]] \
  || fail "Claude-only unpin left the local Claude plugin"
[[ ! -e "$claude_only_codex" ]] \
  || fail "Claude-only unpin created the absent Codex host's directory"
if grep -q '^codex ' "$CALL_LOG"; then
  fail "Claude-only unpin invoked Codex"
fi
ok "Claude-only pin and unpin never touch Codex state"

codex_only_bin="$work/codex-only-bin"
mkdir -p "$codex_only_bin"
ln -s "$bin/codex" "$codex_only_bin/codex"
codex_only_config="$work/codex-only-config"
codex_only_claude="$work/codex-only-claude"
: > "$CALL_LOG"
PATH="$codex_only_bin:/usr/bin:/bin" \
CLAUDE_CONFIG_DIR="$codex_only_claude" \
CODEX_HOME="$codex_only_config" \
FAKE_PHASE=pin bash "$pin" > "$work/codex-only-pin.out"
[[ -f "$codex_only_config/anchor-local-marketplace/.anchor-local-marketplace" ]] \
  || fail "Codex-only pin did not install the local Codex plugin"
[[ ! -e "$codex_only_claude" ]] \
  || fail "Codex-only pin created the absent Claude host's directory"
if grep -q '^claude ' "$CALL_LOG"; then
  fail "Codex-only pin invoked Claude Code"
fi

: > "$CALL_LOG"
PATH="$codex_only_bin:/usr/bin:/bin" \
CLAUDE_CONFIG_DIR="$codex_only_claude" \
CODEX_HOME="$codex_only_config" \
FAKE_PHASE=unpin bash "$unpin" > "$work/codex-only-unpin.out"
[[ ! -e "$codex_only_config/anchor-local-marketplace" ]] \
  || fail "Codex-only unpin left the local Codex marketplace"
[[ ! -e "$codex_only_claude" ]] \
  || fail "Codex-only unpin created the absent Claude host's directory"
if grep -q '^claude ' "$CALL_LOG"; then
  fail "Codex-only unpin invoked Claude Code"
fi
ok "Codex-only pin and unpin never touch Claude Code state"

neither_bin="$work/neither-bin"
mkdir -p "$neither_bin"
neither_claude="$work/neither-claude"
neither_codex="$work/neither-codex"
: > "$CALL_LOG"
PATH="$neither_bin:/usr/bin:/bin" \
CLAUDE_CONFIG_DIR="$neither_claude" \
CODEX_HOME="$neither_codex" \
bash "$pin" > "$work/neither-pin.out"
PATH="$neither_bin:/usr/bin:/bin" \
CLAUDE_CONFIG_DIR="$neither_claude" \
CODEX_HOME="$neither_codex" \
bash "$unpin" > "$work/neither-unpin.out"
[[ ! -e "$neither_claude" && ! -e "$neither_codex" ]] \
  || fail "the no-host case created a host configuration directory"
[[ ! -s "$CALL_LOG" ]] || fail "the no-host case invoked a host CLI"
grep -q 'nothing to pin' "$work/neither-pin.out" \
  || fail "the no-host pin did not explain its no-op"
grep -q 'nothing to unpin' "$work/neither-unpin.out" \
  || fail "the no-host unpin did not explain its no-op"
ok "with neither host installed both scripts are successful no-ops"

echo "# all checks passed"
