#!/usr/bin/env bash
# Functional test for scripts/squash-check.sh's CR-state read: a pushed HEAD
# behind a ready CR must block the squash, and behind a draft CR allow it.
# Stub `glab` / `gh` serve the CR's draft flag, number, and page.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
squash_check="$here/../scripts/squash-check.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-squash-check-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- stubs: `glab mr view --output json` cats $CR_JSON; `gh pr view --json
# --- <fields> --jq <filter>` applies the filter to it, as gh does.
bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "mr view" && -s "$CR_JSON" ]] || exit 1
cat "$CR_JSON"
EOF
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "pr view" && -s "$CR_JSON" ]] || exit 1
while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && filter="$2"; shift; done
jq -r "$filter" "$CR_JSON"
EOF
chmod +x "$bin/glab" "$bin/gh"
export PATH="$bin:$PATH"
export CR_JSON="$work/cr.json"

# make_repo <forge-host> — a feature branch whose HEAD is pushed to a bare
# remote whose path names the forge, so squash-check probes that forge's CLI.
make_repo() {
  local remote="$work/$1/remote.git" repo="$work/$1/repo"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/seed.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m seed
  git init --quiet --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" remote set-head origin main
  git -C "$repo" checkout --quiet -b feat
  printf 'change\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m change
  git -C "$repo" push --quiet -u origin feat
  echo "$repo"
}

for forge in gitlab github; do
  repo=$(make_repo "$forge.com")
  [[ "$forge" == gitlab ]] && key=draft || key=isDraft

  printf '{"%s":false}\n' "$key" > "$CR_JSON"
  o=$(bash "$squash_check" --repo "$repo")
  [[ "$(val SQUASH "$o")" == blocked ]] || fail "$forge: a ready CR must block the squash; got: $o"
  [[ "$(val ALLOW_MESSAGE_AMEND "$o")" == 1 ]] || fail "$forge: a ready CR allows a message amend; got: $o"
  ok "$forge: a ready CR (draft false) blocks the squash"

  printf '{"%s":true}\n' "$key" > "$CR_JSON"
  o=$(bash "$squash_check" --repo "$repo")
  [[ "$(val SQUASH "$o")" == allowed && "$(val SQUASH_FORCE_PUSH "$o")" == 1 ]] \
    || fail "$forge: a draft CR allows the squash with a force-push; got: $o"
  ok "$forge: a draft CR allows the squash"

  if [[ "$forge" == gitlab ]]; then
    printf '{"draft":true,"iid":12,"web_url":"https://gitlab.com/acme/widget/-/merge_requests/12"}\n' > "$CR_JSON"
    want_ref='widget!12' want_url='https://gitlab.com/acme/widget/-/merge_requests/12'
  else
    printf '{"isDraft":true,"number":12,"url":"https://github.com/acme/widget/pull/12"}\n' > "$CR_JSON"
    want_ref='widget#12' want_url='https://github.com/acme/widget/pull/12'
  fi
  o=$(bash "$squash_check" --repo "$repo")
  [[ "$(val CR_REF "$o")" == "$want_ref" && "$(val CR_URL "$o")" == "$want_url" ]] \
    || fail "$forge: the CR is named in the forge's short form, with its page; got: $o"
  ok "$forge: the CR is reported as $want_ref"

  : > "$CR_JSON"
  o=$(bash "$squash_check" --repo "$repo")
  [[ "$(val SQUASH "$o")" == allowed && "$(val SQUASH_FORCE_PUSH "$o")" == 1 ]] \
    || fail "$forge: no CR allows the squash with a force-push; got: $o"
  grep -qx 'CR_REF=' <<<"$o" || fail "$forge: no CR reports an empty CR_REF; got: $o"
  ok "$forge: no CR allows the squash"
done

# A branch with no commit has nothing to amend.
empty="$work/empty"
git init --quiet -b main "$empty"
git -C "$empty" config user.email t@example.com
o=$(bash "$squash_check" --repo "$empty")
[[ "$(val SQUASH "$o")" == blocked ]] || fail "no commit means nothing to squash into: $o"
ok "a branch with no commit blocks the squash"

echo "all squash-check tests passed"
