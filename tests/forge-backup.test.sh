#!/usr/bin/env bash
# Functional test for scripts/forge-backup.sh: before a skill overwrites an
# issue, a CR, or a milestone on the forge, the script saves the object as the
# forge holds it under the repo's git dir (FORGE-13), and reports its url so the
# skill can confirm it is about to change the item it presented.
#
# Drives the real script against stub `gh` / `glab` binaries that log each call
# and serve one fixture per api path.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_sh="$here/../scripts/forge-backup.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
key()  { sed -n "s/^$2=//p" <<<"$1"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-forge-backup-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

bin="$work/bin"
mkdir -p "$bin"
export CALL_LOG="$work/calls.log"
export FIXTURES="$work/fixtures"
mkdir -p "$FIXTURES"

# Both stubs answer `<cli> ... view <n>` and `<cli> api <path>` from
# $FIXTURES/<path with / folded to _>.json; a missing fixture is the forge's 404.
for cli in gh glab; do
  cat > "$bin/$cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALL_LOG"
case "$1" in
  api)        path="$2" ;;
  issue|pr)   path="$1-$3" ;;
  *) echo "stub: unhandled: $*" >&2; exit 1 ;;
esac
file="$FIXTURES/${path//\//_}.json"
[[ -f "$file" ]] || { echo "stub: 404 $path" >&2; exit 1; }
cat "$file"
EOF
  chmod +x "$bin/$cli"
done
export PATH="$bin:$PATH"

make_repo() {
  local host=$1 name=$2 repo="$work/repos/$2"
  git init --quiet -b main "$repo"
  git -C "$repo" remote add origin "https://$host/example/$name.git"
  echo "$repo"
}

fixture() { printf '%s\n' "$2" > "$FIXTURES/${1//\//_}.json"; }

# --- GitHub: an issue and a PR come from `view`, a milestone from the API -----
repo="$(make_repo github.com gh-repo)"
fixture issue-12 '{"number":12,"title":"An issue","body":"issue text","url":"https://github.com/example/gh-repo/issues/12"}'
fixture pr-7 '{"number":7,"title":"A PR","body":"pr text","url":"https://github.com/example/gh-repo/pull/7"}'
fixture 'repos/{owner}/{repo}/milestones/3' '{"number":3,"title":"v2","description":"m text","html_url":"https://github.com/example/gh-repo/milestone/3"}'

for kind_id in issue:12 cr:7 milestone:3; do
  kind=${kind_id%%:*}; id=${kind_id#*:}
  out=$(bash "$backup_sh" --repo "$repo" --kind "$kind" --id "$id")
  path="$(key "$out" BACKUP_PATH)"
  [[ -f "$path" ]] || fail "github $kind: no backup file: $out"
  [[ "$path" == */repos/gh-repo/.git/anchor/backups/* ]] || fail "github $kind: backup outside the git dir: $path"
  [[ "$(key "$out" BACKUP_URL)" == https://github.com/example/gh-repo/* ]] || fail "github $kind: url not reported: $out"
done
jq -e '.body == "issue text"' "$(key "$(bash "$backup_sh" --repo "$repo" --kind issue --id 12)" BACKUP_PATH)" >/dev/null \
  || fail "the backup holds the object as the forge returned it"
[[ "$(key "$(bash "$backup_sh" --repo "$repo" --kind cr --id 7)" BACKUP_TITLE)" == 'A PR' ]] \
  || fail "the title is reported so the skill can name what it is about to change"
ok "github: an issue, a PR, and a milestone are saved under .git/anchor/backups"

# --- GitLab: every kind through the API on :fullpath --------------------------
repo="$(make_repo gitlab.com gl-repo)"
fixture 'projects/:fullpath/issues/12' '{"iid":12,"title":"An issue","description":"issue text","web_url":"https://gitlab.com/example/gl-repo/-/issues/12"}'
fixture 'projects/:fullpath/merge_requests/7' '{"iid":7,"title":"An MR","description":"mr text","web_url":"https://gitlab.com/example/gl-repo/-/merge_requests/7"}'
fixture 'projects/:fullpath/milestones/3' '{"id":3,"title":"v2","description":"m text","web_url":"https://gitlab.com/example/gl-repo/-/milestones/1"}'
for kind_id in issue:12 cr:7 milestone:3; do
  kind=${kind_id%%:*}; id=${kind_id#*:}
  out=$(bash "$backup_sh" --repo "$repo" --kind "$kind" --id "$id")
  [[ -f "$(key "$out" BACKUP_PATH)" ]] || fail "gitlab $kind: no backup file: $out"
  [[ "$(key "$out" BACKUP_URL)" == https://gitlab.com/example/gl-repo/* ]] || fail "gitlab $kind: url not reported: $out"
done
ok "gitlab: an issue, an MR, and a milestone are saved through the API"

# --- A target project other than origin's --------------------------------------
: > "$CALL_LOG"
fixture 'projects/grp%2Fother/issues/5' '{"iid":5,"title":"Elsewhere","description":"x","web_url":"https://gitlab.com/grp/other/-/issues/5"}'
out=$(bash "$backup_sh" --repo "$repo" --kind issue --id 5 --project grp/other)
[[ "$(key "$out" BACKUP_URL)" == https://gitlab.com/grp/other/-/issues/5 ]] || fail "--project should retarget: $out"
[[ "$(key "$out" BACKUP_PATH)" == *grp-other* ]] || fail "the file should name the project it came from: $out"
repo_gh="$work/repos/gh-repo"
fixture 'issue-9' '{"number":9,"title":"t","body":"b","url":"https://github.com/acme/widget/issues/9"}'
bash "$backup_sh" --repo "$repo_gh" --kind issue --id 9 --project acme/widget >/dev/null
grep -qF 'gh issue view 9 -R acme/widget' "$CALL_LOG" || fail "github --project should pass -R: $(cat "$CALL_LOG")"
ok "--project backs up an item in another project"

# --- Nothing to back up is a stop, not a pass ----------------------------------
status=0
out=$(bash "$backup_sh" --repo "$repo" --kind issue --id 404) || status=$?
[[ "$status" -ne 0 ]] || fail "a failed read should fail the backup: $out"
[[ -n "$(key "$out" BACKUP_ERROR)" ]] || fail "a failed read should say why: $out"
[[ -z "$(key "$out" BACKUP_PATH)" ]] || fail "a failed read reports no path: $out"
status=0
bash "$backup_sh" --repo "$repo" --kind release --id 1 >/dev/null 2>&1 || status=$?
[[ "$status" -eq 64 ]] || fail "an unknown kind is a usage error, got $status"
ok "a read that fails stops the write it was guarding"

echo "# all checks passed"
