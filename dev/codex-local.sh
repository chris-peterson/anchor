#!/usr/bin/env bash
# Run this checkout as the anchor plugin Codex loads, and put the released one
# back afterwards.
#
#   dev/codex-local.sh pin     snapshot the checkout into a local marketplace and
#                              install it in place of every installed anchor
#   dev/codex-local.sh unpin   remove the local copy and reinstall the anchor
#                              installs pin removed
#
# Claude Code needs none of this: `claude --plugin-dir .` loads the checkout in
# place. Codex has no such flag and installs a plugin into its own cache from a
# marketplace, so the checkout goes in through a local one and an edit reaches
# Codex only when `pin` runs again.
#
# pin records the installs it removes in the marketplace's marker file, and unpin
# reinstalls exactly those, so a user who installs anchor from a company
# marketplace gets that install back rather than one from another source.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

local_marketplace="anchor-local"
codex_home="${CODEX_HOME:-${HOME}/.codex}"
market_root="$codex_home/anchor-local-marketplace"
marker="$market_root/.anchor-local-marketplace"
local_id="anchor@${local_marketplace}"

fail() { echo "codex-local: $*" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || fail "codex is not on PATH"
command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

# The anchor installs Codex holds, one plugin id per line.
installed_anchors() {
  local json
  json=$(codex plugin list --json) || fail "could not list Codex plugins"
  jq -r '.installed[]? | select(.name == "anchor" and .installed != false) | .pluginId' <<<"$json"
}

local_marketplace_configured() {
  local json
  json=$(codex plugin marketplace list --json) || fail "could not list Codex marketplaces"
  jq -e --arg n "$local_marketplace" 'any(.marketplaces[]?; .name == $n)' <<<"$json" >/dev/null
}

# Only a directory this script made is ever replaced or removed.
guard_market_root() {
  [[ -e "$market_root" || -L "$market_root" ]] || return 0
  [[ -f "$marker" ]] || fail "refusing to touch a directory this script didn't create: $market_root"
}

pin() {
  local snapshot recorded="" id ids
  guard_market_root
  # Each listing is captured in this shell rather than read through a pipe or
  # a process substitution, so a failed one stops the script before it changes
  # anything: `fail` inside `< <(…)` would end only the subshell.
  ids=$(installed_anchors)
  # Re-pinning after an edit keeps the record from the first pin: by then the
  # only anchor installed is the local one.
  [[ ! -f "$marker" ]] || recorded=$(cat "$marker")
  while IFS= read -r id; do
    [[ -n "$id" && "$id" != "$local_id" ]] || continue
    recorded+="${recorded:+$'\n'}$id"
  done <<<"$ids"

  snapshot=$(mktemp -d "$codex_home/anchor-local-marketplace.XXXXXX")
  mkdir -p "$snapshot/.agents/plugins" "$snapshot/plugins/anchor"
  tar -C "$repo_root" --exclude='./.git' -cf - . | tar -C "$snapshot/plugins/anchor" -xf -
  jq -n --arg name "$local_marketplace" '{
    name: $name,
    interface: {displayName: "anchor (local checkout)"},
    plugins: [{
      name: "anchor",
      source: {source: "local", path: "./plugins/anchor"},
      policy: {installation: "AVAILABLE", authentication: "ON_INSTALL"},
      category: "Productivity"
    }]
  }' > "$snapshot/.agents/plugins/marketplace.json"
  printf '%s\n' "$recorded" | sed '/^$/d' > "$snapshot/.anchor-local-marketplace"

  ! local_marketplace_configured || codex plugin marketplace remove "$local_marketplace"
  rm -rf "$market_root"
  mv "$snapshot" "$market_root"

  ids=$(installed_anchors)
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    codex plugin remove "$id"
  done <<<"$ids"
  codex plugin marketplace add "$market_root"
  codex plugin add "$local_id"
  echo "Codex runs anchor from a snapshot of $repo_root ($local_id). Run pin again after an edit, and start a new Codex session."
}

unpin() {
  local id market restored="" ids
  guard_market_root
  [[ -e "$market_root" ]] || { echo "Codex isn't pinned to a local anchor; nothing to undo."; return 0; }

  ids=$(installed_anchors)
  ! grep -qx "$local_id" <<<"$ids" || codex plugin remove "$local_id"
  ! local_marketplace_configured || codex plugin marketplace remove "$local_marketplace"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    market="${id#*@}"
    # A Git marketplace is a snapshot; refresh it so the reinstall is the latest
    # release rather than the one cached when pin ran. A local one has nothing to
    # refresh, and says so by failing.
    codex plugin marketplace upgrade "$market" >/dev/null 2>&1 || true
    codex plugin add "$id"
    restored+="${restored:+, }$id"
  done < "$marker"
  rm -rf "$market_root"

  if [[ -z "$restored" ]]; then
    echo "Removed the local anchor. No anchor was installed before pin, so none was reinstalled."
  else
    echo "Restored $restored. Start a new Codex session to load it."
  fi
}

case "${1:-}" in
  pin)   pin ;;
  unpin) unpin ;;
  *)     echo "usage: dev/codex-local.sh pin|unpin" >&2; exit 64 ;;
esac
