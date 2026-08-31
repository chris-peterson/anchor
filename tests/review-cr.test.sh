#!/usr/bin/env bash
# Functional test for scripts/review-cr.sh, plus the git-range header overrides
# review-diff.sh grew for it (DIFF-19).
#
# The interesting behavior is all about reviewing a change *this checkout is not
# on*: the head arrives through the forge's CR ref namespace rather than a
# branch, the SHAs that a line anchor pins to come from the forge rather than
# from local git, and host/project are read off the CR's own URL because an
# argument can name a CR in another project entirely.
#
# Drives the real script against a local bare remote and stub `gh` / `glab`
# binaries. The remote path embeds `github.com` / `gitlab.com` as a directory
# component because forge detection matches on the origin URL.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
review_cr_sh="$here/../scripts/review-cr.sh"
review_diff_sh="$here/../scripts/review-diff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-review-cr-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub gh: serves $CR_JSON for `pr view`, a fixed login for `api user`.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  pr)   [[ "${2:-}" == view ]] || { echo "stub gh: unhandled pr $2" >&2; exit 1; }
        [[ -s "$CR_JSON" ]] || { echo "no pull requests found" >&2; exit 1; }
        cat "$CR_JSON" ;;
  api)  [[ "${2:-}" == user ]] || { echo "stub gh: unhandled api $2" >&2; exit 1; }
        echo "$FORGE_SELF" ;;
  *) echo "stub gh: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

# --- stub glab: same contract on the MR side.
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  mr)   [[ "${2:-}" == view ]] || { echo "stub glab: unhandled mr $2" >&2; exit 1; }
        [[ -s "$CR_JSON" ]] || { echo "no open merge request" >&2; exit 1; }
        cat "$CR_JSON" ;;
  api)  [[ "${2:-}" == user ]] || { echo "stub glab: unhandled api $2" >&2; exit 1; }
        printf '{"username":"%s"}\n' "$FORGE_SELF" ;;
  *) echo "stub glab: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

chmod +x "$bin/gh" "$bin/glab"
PATH="$bin:$PATH"
export PATH

export CR_JSON="$work/cr.json"
export FORGE_SELF="reviewer"

key() { sed -n "s/^$2=//p" <<<"$1"; }

# Build a repo whose origin reads as <host>, with a CR head published under the
# forge's ref namespace rather than as a branch — the shape a fork-sourced CR
# arrives in, and the one the script has to reach without a checkout.
# Echoes "<repo> <base-sha> <head-sha>".
make_repo() {
  local host=$1 name=$2 ns=$3 iid=$4 remote repo base head
  remote="$work/remotes/$name/$host/example/repo.git"
  repo="$work/repos/$name"
  mkdir -p "$(dirname "$remote")" "$(dirname "$repo")"
  git init --quiet --bare "$remote"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "seed"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" remote set-head origin main
  base=$(git -C "$repo" rev-parse HEAD)

  # The CR's own commits, pushed to the CR ref and then dropped locally, so the
  # only way back to them is the fetch the script performs.
  git -C "$repo" checkout --quiet -b contributor-work
  printf 'one\ntwo\nthree\n' > "$repo/feature.txt"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "Add the feature"
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push --quiet origin "HEAD:refs/${ns}/${iid}/head"
  git -C "$repo" checkout --quiet main
  git -C "$repo" branch --quiet -D contributor-work
  git -C "$repo" gc --quiet --prune=now 2>/dev/null || true

  echo "$repo $base $head"
}

gh_cr_json() {
  jq -n --arg head "$1" --arg base "$2" --arg author "$3" --arg state "$4" \
        --argjson draft "$5" '
    {number: 7, url: "https://github.com/example/repo/pull/7",
     title: "Add the feature", author: {login: $author}, isDraft: $draft,
     state: $state, headRefOid: $head, baseRefOid: $base,
     body: "Why this exists.\n"}' > "$CR_JSON"
}

gl_cr_json() {
  jq -n --arg head "$1" --arg base "$2" --arg author "$3" --arg state "$4" \
        --argjson draft "$5" '
    {iid: 7, web_url: "https://gitlab.com/example/repo/-/merge_requests/7",
     title: "Add the feature", author: {username: $author}, draft: $draft,
     state: $state, sha: $head,
     diff_refs: {base_sha: $base, start_sha: $base, head_sha: $head},
     description: "Why this exists.\n"}' > "$CR_JSON"
}

# --- GitHub: resolves, fetches the head, and pins the SHAs -------------------
read -r repo base head <<<"$(make_repo github.com gh pull 7)"
gh_cr_json "$head" "$base" contributor OPEN false
out=$(bash "$review_cr_sh" 7 --repo "$repo")

[[ "$(key "$out" FORGE)" == github ]]   || fail "GitHub: FORGE=$(key "$out" FORGE)"
[[ "$(key "$out" HOST)" == github.com ]] || fail "GitHub: HOST=$(key "$out" HOST)"
[[ "$(key "$out" PROJECT)" == example/repo ]] || fail "GitHub: PROJECT=$(key "$out" PROJECT)"
[[ "$(key "$out" CR_IID)" == 7 ]]       || fail "GitHub: CR_IID=$(key "$out" CR_IID)"
[[ "$(key "$out" CR_AUTHOR)" == contributor ]] || fail "GitHub: CR_AUTHOR"
[[ "$(key "$out" CR_STATE)" == open ]]  || fail "GitHub: CR_STATE=$(key "$out" CR_STATE)"
[[ "$(key "$out" CR_HEAD_SHA)" == "$head" ]] || fail "GitHub: head not pinned"
[[ "$(key "$out" IS_OWN_CR)" == 0 ]]    || fail "GitHub: IS_OWN_CR should be 0"
ok "GitHub: resolves the CR and pins the head SHA"

# The head was pushed to refs/pull/7/head and deleted locally, so its presence
# proves the fetch reached the CR ref namespace rather than a branch.
git -C "$repo" rev-parse --verify --quiet "${head}^{commit}" >/dev/null \
  || fail "GitHub: CR head was not fetched into the checkout"
ok "GitHub: fetches the head through refs/pull/<n>/head with no branch checkout"

diff_path="$(key "$out" DIFF_PATH)"
desc_path="$(key "$out" DESC_PATH)"
grep -q '^+one$' "$diff_path" || fail "GitHub: diff does not carry the CR's additions"
grep -q 'Why this exists' "$desc_path" || fail "GitHub: description not captured"
[[ "$(key "$out" CHANGED_FILES)" == 1 ]] || fail "GitHub: CHANGED_FILES=$(key "$out" CHANGED_FILES)"
ok "GitHub: writes the description and the range's diff"

findings="$(key "$out" FINDINGS_PATH)"
[[ "$(jq -r '.cr.headSha' "$findings")" == "$head" ]] \
  || fail "GitHub: findings file not seeded with the pinned head"
[[ "$(jq -r '.comments | length' "$findings")" == 0 ]] \
  || fail "GitHub: findings file should start empty"
ok "GitHub: seeds a findings file carrying the pinned head"

# --- The header overrides review-diff.sh grew for this (DIFF-19) -------------
range="$(key "$out" DIFF_RANGE)"
# Drive the dispatcher far enough to build the header, through a stub adapter
# that prints what it was handed instead of launching anything. An adapter is
# picked by mode, so the stub is a mode named `dump`.
mkdir -p "$work/fake-scripts/review"
cp "$review_diff_sh" "$work/fake-scripts/review-diff.sh"
cp -R "$here/../scripts/lib" "$work/fake-scripts/lib"
cat > "$work/fake-scripts/review/dump.sh" <<'EOF'
emit_review() {
  echo "TITLE=$review_title"
  # Compacted so the assertion can read it off one KEY=value line; the computed
  # details are pretty-printed and a commit body spans lines.
  echo "DETAILS=$(jq -c . <<<"$review_details_json")"
  echo "REVIEW_VERDICT=approved"
}
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/dump"
chmod +x "$bin/dump"

hdr=$(cd "$repo" && bash "$work/fake-scripts/review-diff.sh" --mode dump "$range" \
        --title 'Add the feature' --detail CR=https://example/7 --detail author=contributor)
[[ "$(key "$hdr" TITLE)" == "Add the feature" ]] \
  || fail "range mode ignored --title: $(key "$hdr" TITLE)"
[[ "$(jq -r '.[0].label' <<<"$(key "$hdr" DETAILS)")" == CR ]] \
  || fail "range mode ignored --detail"
[[ "$(jq -r '[.[] | select(.label == "commit")] | length' <<<"$(key "$hdr" DETAILS)")" == 0 ]] \
  || fail "overridden details still carry the local commit's rows"
ok "review-diff: git-range --title/--detail replace the local-HEAD header (DIFF-19)"

hdr=$(cd "$repo" && bash "$work/fake-scripts/review-diff.sh" --mode dump "$range")
[[ "$(jq -r '[.[] | select(.label == "commit")] | length' <<<"$(key "$hdr" DETAILS)")" == 1 ]] \
  || fail "without overrides the computed header should still describe the local commit"
ok "review-diff: without overrides the computed range header is unchanged"

# --- GitLab: diff_refs supply all three position SHAs ------------------------
read -r repo base head <<<"$(make_repo gitlab.com gl merge-requests 7)"
gl_cr_json "$head" "$base" contributor opened false
out=$(bash "$review_cr_sh" 7 --repo "$repo")

[[ "$(key "$out" FORGE)" == gitlab ]] || fail "GitLab: FORGE=$(key "$out" FORGE)"
[[ "$(key "$out" PROJECT)" == example/repo ]] || fail "GitLab: PROJECT=$(key "$out" PROJECT)"
[[ "$(key "$out" CR_HEAD_SHA)" == "$head" ]]  || fail "GitLab: head not pinned"
[[ "$(key "$out" CR_BASE_SHA)" == "$base" ]]  || fail "GitLab: base not pinned"
[[ "$(key "$out" CR_START_SHA)" == "$base" ]] || fail "GitLab: start_sha not pinned"
git -C "$repo" rev-parse --verify --quiet "${head}^{commit}" >/dev/null \
  || fail "GitLab: CR head was not fetched into the checkout"
ok "GitLab: resolves the MR and pins all three position SHAs"

# --- A CR the invoking user wrote is reported as such ------------------------
gl_cr_json "$head" "$base" reviewer opened false
out=$(bash "$review_cr_sh" 7 --repo "$repo")
[[ "$(key "$out" IS_OWN_CR)" == 1 ]] || fail "own CR not detected"
ok "reports IS_OWN_CR when the author is the authenticated user"

# --- A merged CR still resolves, with its state reported ---------------------
gl_cr_json "$head" "$base" contributor merged false
out=$(bash "$review_cr_sh" 7 --repo "$repo")
[[ "$(key "$out" CR_STATE)" == merged ]] || fail "CR_STATE=$(key "$out" CR_STATE)"
ok "reports a non-open state rather than resolving it away"

# --- A draft CR is reported so the skill can confirm before reviewing --------
gl_cr_json "$head" "$base" contributor opened true
out=$(bash "$review_cr_sh" 7 --repo "$repo")
[[ "$(key "$out" CR_DRAFT)" == true ]] || fail "CR_DRAFT=$(key "$out" CR_DRAFT)"
ok "reports the draft flag"

# --- No CR resolved: REVIEW_ERROR, non-zero, no half-populated block ---------
: > "$CR_JSON"
set +e
out=$(bash "$review_cr_sh" 999 --repo "$repo" 2>/dev/null)
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "expected a non-zero exit when no CR resolves"
[[ -n "$(key "$out" REVIEW_ERROR)" ]] || fail "expected REVIEW_ERROR, got: $out"
[[ -z "$(key "$out" CR_IID)" ]] || fail "emitted CR_IID on the error path"
ok "no CR resolved -> REVIEW_ERROR and a non-zero exit"

# --- A head the fetch cannot reach fails loudly ------------------------------
gl_cr_json "0000000000000000000000000000000000000000" "$base" contributor opened false
set +e
out=$(bash "$review_cr_sh" 7 --repo "$repo" 2>/dev/null)
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "expected a non-zero exit when the pinned head is unreachable"
[[ "$(key "$out" REVIEW_ERROR)" == *"head"* ]] || fail "expected a head-related REVIEW_ERROR, got: $out"
ok "a head the checkout cannot reach stops rather than reviewing the wrong range"

echo "# all checks passed"
