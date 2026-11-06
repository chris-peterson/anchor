#!/usr/bin/env bash
# Where a copy of forge text goes before anchor overwrites it (FORGE-13).
#
# Sourced, not executed.
#
#   anchor_backup_path <name> <ext>   -> <git-common-dir>/anchor/backups/<name>-<utc>-<pid>.<ext>
#
# Under the git dir rather than a temp dir, so the copy outlives the session
# that wrote it; the common dir, so every worktree of a repo keeps one set.
# Returns 1 outside a git repo, where there is nowhere durable to put it.
anchor_backup_path() {
  local common dir
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  dir="$(cd "$common" && pwd)/anchor/backups"
  mkdir -p "$dir"
  printf '%s/%s-%s-%s.%s\n' "$dir" "$1" "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$2"
}
