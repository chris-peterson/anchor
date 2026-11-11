#!/usr/bin/env bash
# Functional test for scripts/sanitize-check.sh: what a draft should not carry
# to its destination (SPEC SANITIZE-02..06).
# ci-platforms: linux macos windows
#   The scan is one awk program, and BSD awk, gawk, and mawk differ in what
#   regex syntax they accept.
#
# Every fixture value that the scan is meant to find is assembled at run time,
# so this file's own diff carries none of them and commits through the scan
# without a finding.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../scripts/sanitize-check.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-sanitize-check-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

web='https:/''/'
file='file:/''/'
internal='inter''nal'
corp='co''rp'
users='/Us''ers'
home='/ho''me'
com='co''m'
atl='atlassian.ne''t'
bearer='Bear''er abcdefghijklmnop1234'
keyhdr='-----BEGIN OPENSSH PRIV''ATE KEY-----'

run() {
  rc=0
  out="$(bash "$check" "$@" 2>&1)" || rc=$?
}

has() {
  grep -qxF "$1" <<<"$(sed -E 's/^FINDING ([a-z]+) [^ ]*:([0-9]+):[0-9]+ /\1 \2 /' <<<"$out")" \
    || fail "$2: expected '$1' in:"$'\n'"$out"
}

lacks() {
  ! grep -q "$1" <<<"$out" || fail "$2: unexpected '$1' in:"$'\n'"$out"
}

# --- a clean draft ----------------------------------------------------------
cat > "$work/clean.md" <<EOF
## Context

Adds retries to the upload client. See ${web}github.com/acme/widget/pull/12,
${web}docs.github.com/en/actions, and ${web}cbea.ms/git-commit/.

Touches \`SKILL.md\`, \`plugin.yml\`, \`System.Net.Http\`, v1.2.3, and node.js
under src/home/index.ts and ~/src/widget. Example host: api.example.com, and
${web}localhost:8080/health. A long kebab name: task-something-quite-long-here-1.
EOF
run --dest-host github.com --file "$work/clean.md"
[[ $rc -eq 0 ]] || fail "clean draft: exit $rc"$'\n'"$out"
[[ "$(val FINDINGS "$out")" == 0 ]] || fail "clean draft: FINDINGS"
[[ "$(val SANITIZE_DEST "$out")" == github.com ]] || fail "clean draft: SANITIZE_DEST"
[[ "$(val SANITIZE_FORGE "$out")" == github ]] || fail "clean draft: SANITIZE_FORGE"
ok "a clean draft has no findings and exits 0"

# --- hosts ------------------------------------------------------------------
cat > "$work/hosts.md" <<EOF
Ran against gitlab.acme.$internal, then ${web}ci.acme.$corp:8443/job/1.
Mail someone@acme.$com; a single-label host: ${web}jenkins/job/2.
EOF
run --dest-host github.com --file "$work/hosts.md"
[[ $rc -eq 1 ]] || fail "hosts: exit $rc"
has "host 1 gitlab.acme.$internal" "bare internal host"
has "host 1 ci.acme.$corp" "URL host, port dropped"
has "host 2 acme.$com" "an email's domain"
has "host 2 jenkins" "a single-label URL host"
[[ "$(val FINDINGS "$out")" == 4 ]] || fail "hosts: FINDINGS"$'\n'"$out"
ok "foreign hosts are findings, bare and in URLs"

run --dest-host gitlab.acme.$corp --file "$work/hosts.md"
lacks "ci.acme.$corp" "destination's sibling"
has "host 2 acme.$com" "a host outside the destination's parent"
[[ "$(val SANITIZE_FORGE "$out")" == gitlab ]] || fail "self-hosted GitLab forge"
ok "the destination's own host and its parent domain are not findings"

# --- credentials ------------------------------------------------------------
pat="gl""pat-abcdefghij0123456789xy"
ghp="gh""p_abcdefghijklmnopqrstuvwxyz0123456789"
aws="AK""IAABCDEFGHIJKLMNOP"
cat > "$work/creds.md" <<EOF
token $pat and $ghp
key $aws
${web}alice:hunter2secret@github.com/acme/widget.git
Authorization: $bearer
$keyhdr
EOF
run --dest-host github.com --file "$work/creds.md"
has "credential 1 glpat-***" "GitLab token"
has "credential 1 ghp_***" "GitHub token"
has "credential 2 AKIA***" "AWS key id"
has "credential 3 ${web}alice:***@" "user:pass URL"
has "credential 4 Bearer ***" "bearer string"
has "credential 5 $keyhdr" "private key header"
lacks "hunter2secret" "the password is masked"
lacks "0123456789xy" "the token is masked"
ok "credential shapes are findings, printed masked"

# --- paths ------------------------------------------------------------------
cat > "$work/paths.md" <<EOF
Built in $users/alice/src/widget.
Also C:\\Users\\bob\\widget and $home/carol/widget, and ${file}$users/dave/x.
Not: $users/Shared/x, $home/runner/work, ~/src, app$home/index.ts.
EOF
run --dest-host github.com --file "$work/paths.md"
has "path 1 $users/alice/src/widget" "macOS home path, trailing period dropped"
has "path 2 C:\\Users\\bob\\widget" "Windows home path"
has "path 2 $home/carol/widget" "Linux home path"
has "path 2 $users/dave/x" "a file URL's path"
[[ "$(val FINDINGS "$out")" == 4 ]] || fail "paths: FINDINGS"$'\n'"$out"
ok "absolute paths through a user's home are findings"

# --- trackers ---------------------------------------------------------------
cat > "$work/tracker.md" <<EOF
Tracked in ${web}acme.$atl/browse/PROJ-12 and ${web}gitlab.acme.$corp/g/r/-/issues/4.
Public: ${web}gitlab.com/acme/widget/-/issues/9.
EOF
run --dest-host github.com --file "$work/tracker.md"
has "tracker 1 ${web}acme.$atl/browse/PROJ-12" "Jira link"
has "tracker 1 ${web}gitlab.acme.$corp/g/r/-/issues/4" "self-hosted forge issue"
[[ "$(val FINDINGS "$out")" == 2 ]] || fail "tracker: FINDINGS"$'\n'"$out"
run --dest-host gitlab.acme.$corp --file "$work/tracker.md"
has "tracker 1 ${web}acme.$atl/browse/PROJ-12" "Jira from the internal GitLab"
lacks "issues/4" "the destination's own issue"
ok "tracker links the destination's readers can't follow are findings"

# --- deny and allow ---------------------------------------------------------
repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin "git@github.com:acme/widget.git"
cat > "$work/terms.md" <<EOF
Project Bluebird ships after Falcon, on gitlab.acme.$internal and gitlab.other.$internal.
EOF
git -C "$repo" config --add anchor.deny bluebird
git -C "$repo" config --add anchor.github.deny falcon
git -C "$repo" config --add anchor.gitlab.deny ships
git -C "$repo" config --add anchor.allow "acme.$internal"
run --repo "$repo" --file "$work/terms.md"
[[ "$(val SANITIZE_DEST "$out")" == github.com ]] || fail "destination from origin"
has "deny 1 Bluebird" "base deny, case-insensitive"
has "deny 1 Falcon" "forge deny on its forge"
lacks "ships" "another forge's deny"
lacks "gitlab.acme" "an allowed host"
has "host 1 gitlab.other.$internal" "a host no allow term covers"
[[ "$(val ALLOWED "$out")" == 1 ]] || fail "ALLOWED count"$'\n'"$out"
ok "deny terms are findings; allow terms suppress, per forge"

git -C "$repo" config --add anchor.allow bluebird
run --repo "$repo" --file "$work/terms.md"
has "deny 1 Bluebird" "allow never suppresses a deny term"
git -C "$repo" config --add anchor.gitlab.allow "other.$internal"
run --repo "$repo" --file "$work/terms.md"
has "host 1 gitlab.other.$internal" "another forge's allow"
run --repo "$repo" --dest-host gitlab.example.com --file "$work/terms.md"
lacks "gitlab.other" "the forge's own allow"
has "deny 1 ships" "the forge's own deny"
ok "an allow term leaves deny alone, and forge keys follow the destination"

# --- the staged diff --------------------------------------------------------
printf 'one\ntwo\nthree\n' > "$repo/kept.txt"
git -C "$repo" add kept.txt
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -qm init
printf 'one\ntwo at gitlab.acme.%s\nthree\nhost gitlab.second.%s\n' "$corp" "$corp" > "$repo/kept.txt"
printf 'see %s/erin/x\n' "$users" > "$repo/other.txt"
git -C "$repo" add kept.txt other.txt
run --repo "$repo" --staged --path kept.txt
has "host 2 gitlab.acme.$corp" "an added line, new-file numbering"
has "host 4 gitlab.second.$corp" "a second hunk"
lacks "erin" "a path outside --path"
grep -q "^FINDING host kept.txt:2:" <<<"$out" || fail "diff source is the repo path"$'\n'"$out"
run --repo "$repo" --staged
has "path 1 $users/erin/x" "every staged file without --path"
printf 'one\nthree\nhost gitlab.second.%s\n' "$corp" > "$repo/kept.txt"
git -C "$repo" add kept.txt
run --repo "$repo" --staged --path kept.txt
lacks "gitlab.acme" "a removed line"
ok "--staged scans the added lines of the index"

# --- text a locale can't decode ---------------------------------------------
printf 'caf\303\251 ran on gitlab.acme.%s, then \342\200\224 and a stray \377 byte\n' "$corp" > "$work/bytes.md"
run --dest-host github.com --file "$work/bytes.md"
[[ $rc -eq 1 ]] || fail "multibyte and invalid bytes: exit $rc"$'\n'"$out"
has "host 1 gitlab.acme.$corp" "a finding after multibyte text"
ok "multibyte text and invalid bytes scan rather than abort"

# --- errors -----------------------------------------------------------------
run --file "$work/clean.md" --repo "$work"
[[ $rc -eq 65 ]] || fail "no destination: exit $rc"
run --dest-host github.com --file "$work/absent.md"
[[ $rc -eq 66 ]] || fail "unreadable file: exit $rc"
run --dest-host github.com
[[ $rc -eq 64 ]] || fail "nothing to scan: exit $rc"
run --dest-host github.com --file "$work/clean.md" --path x
[[ $rc -eq 64 ]] || fail "--path without --staged: exit $rc"
ok "usage, destination, and unreadable-file errors exit 64, 65, 66"
