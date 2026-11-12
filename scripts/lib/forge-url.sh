#!/usr/bin/env bash
# Turn the `origin` remote into forge web addresses, for the scripts that have a
# sha or a ref in hand and need something a person or a sibling tool can open.
#
# Sourced, not executed.
#
#   anchor_repo_web_url               -> https://github.com/owner/repo
#   anchor_commit_web_url <sha>       -> https://github.com/owner/repo/commit/<sha>
#
# Both print nothing where `origin` is absent or is neither GitHub nor GitLab:
# there is no address to build, and a caller announcing an empty field says that
# more honestly than one carrying a guess.
#
# The CR helpers alongside them (anchor_forge_self, anchor_cr_write_description,
# anchor_cr_reference) carry the forge calls more than one script makes.
#
# The remote comes in four shapes that all have to reach the same web address —
# `https://host/path`, `ssh://git@host:2222/path`, the scp-like
# `git@host:group/path`, and any of them with a trailing `.git`. The path may be
# nested more than one level deep, which GitLab subgroups make routine, so the
# host is split off rather than the path being parsed into owner and repo.
#
# Credentials in the remote are dropped rather than carried through. A remote
# cloned with a token in it (`https://user:token@host/path`) would otherwise put
# that token in an announcement, on the agent's stdout, and in whatever a
# subscriber writes to disk.

# Which forge, read from the whole remote URL with the same patterns
# scripts/prepare-review.sh uses, so the two cannot disagree about a repo. A
# self-hosted GitLab matches on its own name; a GitHub Enterprise host that
# carries neither name reads as `none`, as it does everywhere else in anchor.
anchor_forge_of_origin() {
  local url
  url=$(git remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) printf 'github\n' ;;
    *gitlab*)     printf 'gitlab\n' ;;
    *)            printf 'none\n' ;;
  esac
}

# The signed-in user's login on <forge>. On failure it prints the CLI's output
# instead and returns 1, so a caller can hand that text to its own error report.
anchor_forge_self() {
  local out
  case "$1" in
    github) out=$(gh api user 2>&1) || { printf '%s\n' "$out"; return 1; }
            jq -r '.login // empty' <<<"$out" ;;
    gitlab) out=$(glab api user 2>&1) || { printf '%s\n' "$out"; return 1; }
            jq -r '.username // empty' <<<"$out" ;;
    *)      printf 'origin is neither GitHub nor GitLab\n'; return 1 ;;
  esac
}

# Replace CR <iid>'s description with <file>. On failure it prints the CLI's
# output and returns 1.
anchor_cr_write_description() {
  local out
  case "$1" in
    github) out=$(gh pr edit "$2" --body-file "$3" 2>&1) ;;
    gitlab) out=$(glab api -X PUT "projects/:fullpath/merge_requests/$2" -F "description=@$3" 2>&1) ;;
    *)      out="origin is neither GitHub nor GitLab"; false ;;
  esac || { printf '%s\n' "$out"; return 1; }
}

# A CR as its forge writes it, from the CR's web URL and number: the project's
# own name, then # (pull request) or ! (merge request) and the number, with
# <gap> between the name and the marker.
anchor_cr_reference() {
  local url="$1" n="$2" gap="${3:-}" mark='#' path
  case "$url" in */merge_requests/*) mark='!' ;; esac
  path="${url%/pull/*}"
  path="${path%/-/merge_requests/*}"
  path="${path%/merge_requests/*}"
  printf '%s%s%s%s\n' "${path##*/}" "$gap" "$mark" "$n"
}

anchor_repo_web_url() {
  local url host path port_or_path
  url=$(git remote get-url origin 2>/dev/null || true)
  [[ -n "$url" ]] || return 0
  [[ "$(anchor_forge_of_origin)" != "none" ]] || return 0

  url="${url%.git}"
  url="${url%/}"
  url="${url#*://}"
  # Userinfo, when it sits before the path rather than inside it.
  case "${url%%/*}" in *@*) url="${url#*@}" ;; esac

  case "$url" in
    *:*)
      host="${url%%:*}"
      port_or_path="${url#*:}"
      # `host:2222/path` from an ssh:// remote, versus `host:group/path` from an
      # scp-like one. Only the first has digits alone ahead of the slash.
      case "$port_or_path" in
        [0-9]*/*)
          [[ "${port_or_path%%/*}" =~ ^[0-9]+$ ]] \
            && path="${port_or_path#*/}" || path="$port_or_path"
          ;;
        *) path="$port_or_path" ;;
      esac
      ;;
    */*)
      host="${url%%/*}"
      path="${url#*/}"
      ;;
    *) return 0 ;;
  esac

  [[ -n "$host" && -n "$path" ]] || return 0
  printf 'https://%s/%s\n' "$host" "$path"
}

# GitLab routes everything under a project through `/-/`, which keeps a ref named
# like a route from colliding with one.
anchor_commit_web_url() {
  local sha="${1:-}" base
  [[ -n "$sha" ]] || return 0
  base=$(anchor_repo_web_url)
  [[ -n "$base" ]] || return 0
  case "$(anchor_forge_of_origin)" in
    github) printf '%s/commit/%s\n'   "$base" "$sha" ;;
    gitlab) printf '%s/-/commit/%s\n' "$base" "$sha" ;;
  esac
}
