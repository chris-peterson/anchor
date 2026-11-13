#!/usr/bin/env bash
# Functional test for scripts/forge-backup.sh: before a skill overwrites an
# issue, a CR, or a milestone on the forge, the script saves the object as the
# forge holds it under the repo's git dir (FORGE-13), refuses the write when
# the item isn't the one the skill presented, and keeps the copy's path out of
# its output unless it refuses.
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
# The newest backup in <repo> whose name starts with <prefix>.
newest() { find "$1/.git/anchor/backups" -name "$2-*" -print 2>/dev/null | sort | tail -n 1; }

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

for kind_url in issue:12:issues/12 cr:7:pull/7 milestone:3:milestone/3; do
  IFS=: read -r kind id tail <<<"$kind_url"
  out=$(bash "$backup_sh" --repo "$repo" --kind "$kind" --id "$id" --expect-url "https://github.com/example/gh-repo/$tail")
  [[ "$(key "$out" BACKUP_SAVED)" == 1 ]] || fail "github $kind: not saved: $out"
  [[ -f "$(newest "$repo" "$kind-$id")" ]] || fail "github $kind: no backup file under the git dir: $out"
  ! grep -q "$repo/.git" <<<"$out" || fail "github $kind: a save that succeeds should not report its path: $out"
done
jq -e '.body == "issue text"' "$(newest "$repo" issue-12)" >/dev/null \
  || fail "the backup holds the object as the forge returned it"
grep -q '^gh pr view 7 --json .*isDraft' "$CALL_LOG" || fail "a PR's backup should hold its draft flag: $(cat "$CALL_LOG")"
ok "github: an issue, a PR, and a milestone are saved under .git/anchor/backups"

# --- GitLab: every kind through the API on :fullpath --------------------------
repo="$(make_repo gitlab.com gl-repo)"
fixture 'projects/:fullpath/issues/12' '{"iid":12,"title":"An issue","description":"issue text","web_url":"https://gitlab.com/example/gl-repo/-/issues/12"}'
fixture 'projects/:fullpath/merge_requests/7' '{"iid":7,"title":"An MR","description":"mr text","web_url":"https://gitlab.com/example/gl-repo/-/merge_requests/7"}'
fixture 'projects/:fullpath/milestones/3' '{"id":3,"title":"v2","description":"m text","web_url":"https://gitlab.com/example/gl-repo/-/milestones/1"}'
for kind_url in issue:12:issues/12 cr:7:merge_requests/7 milestone:3:milestones/1; do
  IFS=: read -r kind id tail <<<"$kind_url"
  out=$(bash "$backup_sh" --repo "$repo" --kind "$kind" --id "$id" --expect-url "https://gitlab.com/example/gl-repo/-/$tail")
  [[ "$(key "$out" BACKUP_SAVED)" == 1 ]] || fail "gitlab $kind: not saved: $out"
  [[ -f "$(newest "$repo" "$kind-$id")" ]] || fail "gitlab $kind: no backup file: $out"
done
ok "gitlab: an issue, an MR, and a milestone are saved through the API"

# --- A target project other than origin's --------------------------------------
: > "$CALL_LOG"
fixture 'projects/grp%2Fother/issues/5' '{"iid":5,"title":"Elsewhere","description":"x","web_url":"https://gitlab.com/grp/other/-/issues/5"}'
out=$(bash "$backup_sh" --repo "$repo" --kind issue --id 5 --project grp/other --expect-url https://gitlab.com/grp/other/-/issues/5)
[[ "$(key "$out" BACKUP_SAVED)" == 1 ]] || fail "--project should retarget: $out"
[[ -f "$(newest "$repo" grp-other-issue-5)" ]] || fail "the file should name the project it came from: $(ls "$repo/.git/anchor/backups")"
repo_gh="$work/repos/gh-repo"
fixture 'issue-9' '{"number":9,"title":"t","body":"b","url":"https://github.com/acme/widget/issues/9"}'
bash "$backup_sh" --repo "$repo_gh" --kind issue --id 9 --project acme/widget --expect-url https://github.com/acme/widget/issues/9 >/dev/null
grep -qF 'gh issue view 9 -R acme/widget' "$CALL_LOG" || fail "github --project should pass -R: $(cat "$CALL_LOG")"
ok "--project backs up an item in another project"

# --- The wrong item is a stop, and names the copy --------------------------------
status=0
out=$(bash "$backup_sh" --repo "$repo" --kind issue --id 12 --expect-url https://gitlab.com/example/gl-repo/-/issues/13) || status=$?
[[ "$status" -eq 1 ]] || fail "a backup of another item should fail: $status $out"
err="$(key "$out" BACKUP_ERROR)"
[[ "$err" == *issues/12*'(An issue)'*issues/13*refusing*/repos/gl-repo/.git/anchor/backups/issue-12-* ]] \
  || fail "the refusal should name both items and the saved copy: $out"
[[ -z "$(key "$out" BACKUP_SAVED)" ]] || fail "a refused backup is not saved-and-clear: $out"
ok "a backup of an item other than the one presented refuses the write, naming the copy"

# --- Nothing to back up is a stop, not a pass ----------------------------------
status=0
out=$(bash "$backup_sh" --repo "$repo" --kind issue --id 404 --expect-url https://gitlab.com/example/gl-repo/-/issues/404) || status=$?
[[ "$status" -ne 0 ]] || fail "a failed read should fail the backup: $out"
[[ -n "$(key "$out" BACKUP_ERROR)" ]] || fail "a failed read should say why: $out"
[[ -z "$(key "$out" BACKUP_SAVED)" ]] || fail "a failed read is not saved: $out"
status=0
bash "$backup_sh" --repo "$repo" --kind release --id 1 --expect-url x >/dev/null 2>&1 || status=$?
[[ "$status" -eq 64 ]] || fail "an unknown kind is a usage error, got $status"
status=0
bash "$backup_sh" --repo "$repo" --kind issue --id 12 >/dev/null 2>&1 || status=$?
[[ "$status" -eq 64 ]] || fail "a backup with no item to match is a usage error, got $status"
ok "a read that fails stops the write it was guarding"

echo "# all checks passed"
