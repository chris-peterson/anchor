#!/usr/bin/env bash
# Replace installed Anchor plugins with this checkout for local development.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

local_marketplace="${ANCHOR_LOCAL_MARKETPLACE:-anchor-local}"
claude_config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
claude_skills_dir="${ANCHOR_CLAUDE_SKILLS_DIR:-$claude_config_dir/skills}"
claude_local_path="$claude_skills_dir/anchor"
codex_config_dir="${CODEX_HOME:-${HOME}/.codex}"
codex_marketplace_root="${ANCHOR_CODEX_LOCAL_MARKETPLACE_DIR:-$codex_config_dir/anchor-local-marketplace}"
snapshot_root=""
has_claude=0
has_codex=0
command -v claude >/dev/null 2>&1 && has_claude=1
command -v codex >/dev/null 2>&1 && has_codex=1

cleanup() {
  [[ -z "$snapshot_root" ]] || rm -rf "$snapshot_root"
}
trap cleanup EXIT

fail() {
  echo "pin-local: $*" >&2
  exit 1
}

anchor_ids() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\(anchor@[^\"]*\)\".*/\1/p"
}

remove_claude_marketplace_installs() {
  local installed_json plugin_id
  installed_json="$(claude plugin list --json)" \
    || fail "could not list Claude Code plugins"

  while IFS= read -r plugin_id; do
    [[ -n "$plugin_id" ]] || continue
    [[ "$plugin_id" == "anchor@skills-dir" ]] && continue
    claude plugin uninstall --scope user --keep-data "$plugin_id"
  done < <(printf '%s\n' "$installed_json" | anchor_ids id)
}

remove_codex_installs() {
  local installed_json plugin_id
  installed_json="$(codex plugin list --json)" \
    || fail "could not list Codex plugins"

  while IFS= read -r plugin_id; do
    [[ -n "$plugin_id" ]] || continue
    codex plugin remove "$plugin_id"
  done < <(printf '%s\n' "$installed_json" | anchor_ids pluginId)
}

codex_marketplace_is_configured() {
  local marketplaces_json
  marketplaces_json="$(codex plugin marketplace list --json)" \
    || fail "could not list Codex marketplaces"
  printf '%s\n' "$marketplaces_json" \
    | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${local_marketplace}\""
}

prepare_codex_snapshot() {
  [[ "$codex_marketplace_root" == */anchor-local-marketplace ]] \
    || fail "local Codex marketplace path must end in anchor-local-marketplace: $codex_marketplace_root"
  case "$codex_marketplace_root/" in
    "$repo_root/"*) fail "local Codex marketplace must live outside the Anchor checkout" ;;
  esac
  if [[ -e "$codex_marketplace_root" || -L "$codex_marketplace_root" ]]; then
    [[ -f "$codex_marketplace_root/.anchor-local-marketplace" ]] \
      || fail "refusing to replace an unrecognized Codex marketplace path: $codex_marketplace_root"
  fi

  mkdir -p "$(dirname "$codex_marketplace_root")"
  snapshot_root="$(mktemp -d /tmp/anchor-local-marketplace.XXXXXX)"

  mkdir -p "$snapshot_root/.agents/plugins" "$snapshot_root/plugins/anchor"
  : > "$snapshot_root/.anchor-local-marketplace"
  (
    cd "$repo_root"
    tar --exclude='./.git' -cf - .
  ) | (
    cd "$snapshot_root/plugins/anchor"
    tar -xf -
  )

  cat > "$snapshot_root/.agents/plugins/marketplace.json" <<JSON
{
  "name": "$local_marketplace",
  "interface": {
    "displayName": "Anchor local development"
  },
  "plugins": [
    {
      "name": "anchor",
      "source": {
        "source": "local",
        "path": "./plugins/anchor"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
JSON

  if codex_marketplace_is_configured; then
    codex plugin marketplace remove "$local_marketplace"
  fi
  [[ ! -e "$codex_marketplace_root" && ! -L "$codex_marketplace_root" ]] \
    || rm -rf "$codex_marketplace_root"
  mv "$snapshot_root" "$codex_marketplace_root"
  snapshot_root=""
}

if [[ "$has_claude" -eq 0 && "$has_codex" -eq 0 ]]; then
  echo "Neither Claude Code nor Codex is installed; nothing to pin."
  exit 0
fi

if [[ "$has_claude" -eq 1 ]]; then
  if [[ -L "$claude_local_path" ]]; then
    claude_link_target="$(cd "$claude_local_path" 2>/dev/null && pwd -P)" \
      || fail "refusing to replace a broken Claude plugin symlink: $claude_local_path"
    [[ "$claude_link_target" == "$repo_root" ]] \
      || fail "refusing to replace a Claude plugin symlink to another checkout: $claude_link_target"
  elif [[ -e "$claude_local_path" ]]; then
    fail "refusing to replace non-symlink Claude plugin path: $claude_local_path"
  fi
fi

if [[ "$has_codex" -eq 1 ]]; then
  command -v tar >/dev/null 2>&1 || fail "required command not found: tar"
  [[ "$local_marketplace" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "invalid local marketplace name: $local_marketplace"
  prepare_codex_snapshot
fi

if [[ "$has_claude" -eq 1 ]]; then
  mkdir -p "$claude_skills_dir"
  [[ ! -L "$claude_local_path" ]] || rm "$claude_local_path"
  ln -s "$repo_root" "$claude_local_path"
  remove_claude_marketplace_installs
  echo "Claude Code pinned to $repo_root (anchor@skills-dir)."
else
  echo "Claude Code not found; skipped."
fi

if [[ "$has_codex" -eq 1 ]]; then
  remove_codex_installs
  codex plugin marketplace add "$codex_marketplace_root"
  codex plugin add "anchor@${local_marketplace}"
  echo "Codex pinned to a snapshot of $repo_root (anchor@${local_marketplace})."
else
  echo "Codex not found; skipped."
fi

echo "Start a new session in each pinned host to load the local plugin."
