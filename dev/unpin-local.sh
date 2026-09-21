#!/usr/bin/env bash
# Remove local Anchor development installs and restore the latest release.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

official_marketplace="${ANCHOR_OFFICIAL_MARKETPLACE:-chris-peterson}"
official_marketplace_source="${ANCHOR_OFFICIAL_MARKETPLACE_SOURCE:-chris-peterson/claude-marketplace}"
local_marketplace="${ANCHOR_LOCAL_MARKETPLACE:-anchor-local}"
claude_config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
claude_skills_dir="${ANCHOR_CLAUDE_SKILLS_DIR:-$claude_config_dir/skills}"
claude_local_path="$claude_skills_dir/anchor"
codex_config_dir="${CODEX_HOME:-${HOME}/.codex}"
codex_marketplace_root="${ANCHOR_CODEX_LOCAL_MARKETPLACE_DIR:-$codex_config_dir/anchor-local-marketplace}"
has_claude=0
has_codex=0
command -v claude >/dev/null 2>&1 && has_claude=1
command -v codex >/dev/null 2>&1 && has_codex=1

fail() {
  echo "unpin-local: $*" >&2
  exit 1
}

anchor_ids() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\(anchor@[^\"]*\)\".*/\1/p"
}

claude_marketplace_is_configured() {
  local marketplaces_json
  marketplaces_json="$(claude plugin marketplace list --json)" \
    || fail "could not list Claude Code marketplaces"
  printf '%s\n' "$marketplaces_json" \
    | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${official_marketplace}\""
}

codex_marketplace_is_configured() {
  local marketplace="$1" marketplaces_json
  marketplaces_json="$(codex plugin marketplace list --json)" \
    || fail "could not list Codex marketplaces"
  printf '%s\n' "$marketplaces_json" \
    | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${marketplace}\""
}

remove_other_claude_installs() {
  local installed_json plugin_id
  installed_json="$(claude plugin list --json)" \
    || fail "could not list Claude Code plugins"

  while IFS= read -r plugin_id; do
    [[ -n "$plugin_id" ]] || continue
    [[ "$plugin_id" == "anchor@${official_marketplace}" ]] && continue
    [[ "$plugin_id" == "anchor@skills-dir" ]] && continue
    claude plugin uninstall --scope user --keep-data "$plugin_id"
  done < <(printf '%s\n' "$installed_json" | anchor_ids id)
}

remove_other_codex_installs() {
  local installed_json plugin_id
  installed_json="$(codex plugin list --json)" \
    || fail "could not list Codex plugins"

  while IFS= read -r plugin_id; do
    [[ -n "$plugin_id" ]] || continue
    [[ "$plugin_id" == "anchor@${official_marketplace}" ]] && continue
    codex plugin remove "$plugin_id"
  done < <(printf '%s\n' "$installed_json" | anchor_ids pluginId)
}

if [[ "$has_claude" -eq 0 && "$has_codex" -eq 0 ]]; then
  echo "Neither Claude Code nor Codex is installed; nothing to unpin."
  exit 0
fi

if [[ "$has_claude" -eq 1 ]]; then
  [[ "$official_marketplace" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "invalid official marketplace name: $official_marketplace"
  if [[ -L "$claude_local_path" ]]; then
    claude_link_target="$(cd "$claude_local_path" 2>/dev/null && pwd -P)" \
      || fail "refusing to remove a broken Claude plugin symlink: $claude_local_path"
    [[ "$claude_link_target" == "$repo_root" ]] \
      || fail "refusing to remove a Claude plugin symlink to another checkout: $claude_link_target"
  elif [[ -e "$claude_local_path" ]]; then
    fail "refusing to remove non-symlink Claude plugin path: $claude_local_path"
  fi
fi

if [[ "$has_codex" -eq 1 ]]; then
  [[ "$official_marketplace" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "invalid official marketplace name: $official_marketplace"
  [[ "$local_marketplace" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "invalid local marketplace name: $local_marketplace"
  if [[ -e "$codex_marketplace_root" || -L "$codex_marketplace_root" ]]; then
    [[ "$codex_marketplace_root" == */anchor-local-marketplace ]] \
      || fail "refusing to remove unexpected Codex marketplace path: $codex_marketplace_root"
    case "$codex_marketplace_root/" in
      "$repo_root/"*) fail "refusing to remove a path inside the Anchor checkout" ;;
    esac
    [[ -f "$codex_marketplace_root/.anchor-local-marketplace" ]] \
      || fail "refusing to remove an unrecognized Codex marketplace path: $codex_marketplace_root"
  fi
fi

if [[ "$has_claude" -eq 1 ]]; then
  if claude_marketplace_is_configured; then
    claude plugin marketplace update "$official_marketplace"
  else
    claude plugin marketplace add --scope user "$official_marketplace_source"
  fi

  # Reinstall instead of merely enabling so the restored copy is the latest one
  # advertised by the refreshed canonical marketplace.
  if claude plugin list --json \
    | anchor_ids id \
    | grep -qx "anchor@${official_marketplace}"; then
    claude plugin uninstall --scope user --keep-data "anchor@${official_marketplace}"
  fi
  claude plugin install --scope user "anchor@${official_marketplace}"
  remove_other_claude_installs
  [[ ! -L "$claude_local_path" ]] || rm "$claude_local_path"
  echo "Claude Code restored to anchor@${official_marketplace}."
else
  echo "Claude Code not found; skipped."
fi

if [[ "$has_codex" -eq 1 ]]; then
  if codex_marketplace_is_configured "$official_marketplace"; then
    codex plugin marketplace upgrade "$official_marketplace"
  else
    codex plugin marketplace add "$official_marketplace_source"
  fi

  if codex plugin list --json \
    | anchor_ids pluginId \
    | grep -qx "anchor@${official_marketplace}"; then
    codex plugin remove "anchor@${official_marketplace}"
  fi
  codex plugin add "anchor@${official_marketplace}"
  remove_other_codex_installs

  if codex_marketplace_is_configured "$local_marketplace"; then
    codex plugin marketplace remove "$local_marketplace"
  fi
  if [[ -e "$codex_marketplace_root" || -L "$codex_marketplace_root" ]]; then
    rm -rf "$codex_marketplace_root"
  fi
  echo "Codex restored to anchor@${official_marketplace}."
else
  echo "Codex not found; skipped."
fi

echo "Start a new session in each restored host to load the official plugin."
