#!/usr/bin/env bash
# Functional test for scripts/lib/forge-url.sh.
#
# What it holds up is the set of remote shapes that all have to reach one web
# address. A clone's remote depends on how it was made — the forge's HTTPS
# button, an SSH one, `ssh://` with a port, a scp-like `git@host:path` — and
# `commit.pushed` carries whatever comes out, so a shape parsed wrong ships a
# URL that 404s to every subscriber rather than failing anywhere visible.
#
# The credentialed remote is here for a different reason: a token in `origin`
# must not reach an announcement.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/forge-url.sh
source "$here/../scripts/lib/forge-url.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-forge-url-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

repo="$work/repo"
git init --quiet -b main "$repo"
cd "$repo"

set_origin() {
  git remote remove origin >/dev/null 2>&1 || true
  [[ -z "${1:-}" ]] || git remote add origin "$1"
}

# expect <remote> <forge> <repo-url> <commit-url>
expect() {
  local remote="$1" forge="$2" web="$3" commit="$4" got
  set_origin "$remote"

  got=$(anchor_forge_of_origin)
  [[ "$got" == "$forge" ]] || fail "$remote: forge '$got', expected '$forge'"

  got=$(anchor_repo_web_url)
  [[ "$got" == "$web" ]] || fail "$remote: web url '$got', expected '$web'"

  got=$(anchor_commit_web_url deadbee)
  [[ "$got" == "$commit" ]] || fail "$remote: commit url '$got', expected '$commit'"
}

expect https://github.com/owner/repo.git github \
  https://github.com/owner/repo \
  https://github.com/owner/repo/commit/deadbee
expect https://github.com/owner/repo github \
  https://github.com/owner/repo \
  https://github.com/owner/repo/commit/deadbee
expect git@github.com:owner/repo.git github \
  https://github.com/owner/repo \
  https://github.com/owner/repo/commit/deadbee
ok "GitHub over https and scp-like ssh, with and without the .git suffix"

expect https://gitlab.com/group/repo.git gitlab \
  https://gitlab.com/group/repo \
  https://gitlab.com/group/repo/-/commit/deadbee
expect git@gitlab.example.com:group/sub/deeper/repo.git gitlab \
  https://gitlab.example.com/group/sub/deeper/repo \
  https://gitlab.example.com/group/sub/deeper/repo/-/commit/deadbee
ok "GitLab routes a commit under /-/, and a subgroup path survives whole"

expect ssh://git@gitlab.example.com:2222/group/repo.git gitlab \
  https://gitlab.example.com/group/repo \
  https://gitlab.example.com/group/repo/-/commit/deadbee
ok "an ssh:// port is dropped rather than read as the first path segment"

# A group whose name begins with a digit is not a port.
expect git@gitlab.example.com:2team/repo.git gitlab \
  https://gitlab.example.com/2team/repo \
  https://gitlab.example.com/2team/repo/-/commit/deadbee
ok "a numeric-leading group name is kept"

# The reason the userinfo strip exists: whatever is here reaches an announcement.
expect https://oauth2:glpat-SECRET@gitlab.example.com/group/repo.git gitlab \
  https://gitlab.example.com/group/repo \
  https://gitlab.example.com/group/repo/-/commit/deadbee
ok "credentials in the remote are dropped, not carried into the URL"

# Both degraded inputs, exercised rather than assumed: these are the reason
# `commit.pushed` declares its uri optional.
expect https://bitbucket.org/owner/repo.git none "" ""
ok "a host that is neither forge yields no address"

set_origin ""
[[ "$(anchor_forge_of_origin)" == "none" ]] || fail "no origin: forge not none"
[[ -z "$(anchor_repo_web_url)" ]]           || fail "no origin: built a web url"
[[ -z "$(anchor_commit_web_url deadbee)" ]] || fail "no origin: built a commit url"
ok "a repo with no origin at all yields no address"

set_origin https://github.com/owner/repo.git
[[ -z "$(anchor_commit_web_url)" ]] || fail "built a commit url with no sha"
ok "no sha yields no commit url"

echo "PASS"
