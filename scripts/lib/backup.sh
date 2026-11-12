#!/usr/bin/env bash
# Where a copy of forge text goes before anchor overwrites it (FORGE-13).
#
# Sourced, not executed.
#
#   anchor_backup_path <name> <ext>   -> <git-common-dir>/anchor/backups/<name>-<utc>-<pid>.<ext>
#   anchor_backup_cr <n> <cr-url>     -> the path scripts/forge-backup.sh saved CR <n> to
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

# Save CR <n> through scripts/forge-backup.sh, for a script about to edit it
# without an approval step to match the item against. The saved CR has to be
# <cr-url>, the one the caller read and is about to write; anything else means
# the number reached a different CR, so the caller must not write. On a failed
# read or a mismatch it prints the reason and returns 1.
anchor_backup_cr() {
  local out path url
  if ! out=$(bash "$(dirname "${BASH_SOURCE[0]}")/../forge-backup.sh" --kind cr --id "$1" 2>&1); then
    grep -v '^RESOLVED_VIA=' <<<"$out" | sed 's/^BACKUP_ERROR=//'
    return 1
  fi
  path=$(sed -n 's/^BACKUP_PATH=//p' <<<"$out")
  url=$(sed -n 's/^BACKUP_URL=//p' <<<"$out")
  if [[ -z "$url" || "$url" != "$2" ]]; then
    printf 'the backup saved %s, not %s, the CR about to be written; refusing the write (saved copy: %s)\n' \
      "${url:-a CR with no url}" "$2" "$path"
    return 1
  fi
  printf '%s\n' "$path"
}
