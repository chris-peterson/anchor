#!/usr/bin/env bash
# Functional test for scripts/release-publish.sh.
#
# Drives the real script against stub `gh` / `glab` that record each call, so
# what is asserted is the invocation each forge gets: the notes by file and never
# generated, the level under the input name the caller passed, and the URL read
# back rather than assumed. The refusals matter as much: a dispatch on GitLab,
# which has no equivalent, and a release with no notes both stop before any
# forge call.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
publish_sh="$here/../scripts/release-publish.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  echo "PASS"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-release-publish-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$CALL_LOG"
[[ "${FAIL_ON:-}" != "${1:-} ${2:-}" ]] || { echo "HTTP 422: Unexpected inputs provided" >&2; exit 1; }
case "${1:-} ${2:-}" in
  "release create") echo "https://github.com/acme/widget/releases/tag/$3" ;;
  "release view")   echo "https://github.com/acme/widget/releases/tag/$3" ;;
  "workflow run")   echo "✓ Created workflow_dispatch event for $3 at main"
                    echo "https://github.com/acme/widget/actions/runs/123456" ;;
  *) echo "stub gh: unhandled command: $*" >&2; exit 1 ;;
esac
EOF

cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "glab $*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
  "release create") echo "created $3" ;;
  "release view")   printf '{"tag_name":"%s","_links":{"self":"https://gitlab.example.com/acme/widget/-/releases/%s"}}\n' "$3" "$3" ;;
  *) echo "stub glab: unhandled command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh" "$bin/glab"
PATH="$bin:$PATH"
CALL_LOG="$work/calls.log"
export PATH CALL_LOG

repo_for() {
  local dir="$work/$1"
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "$2"
  printf '%s\n' "$dir"
}

gh_repo=$(repo_for gh-repo git@github.com:acme/widget.git)
gl_repo=$(repo_for gl-repo git@gitlab.example.com:acme/widget.git)
notes="$work/notes.md"
printf '### Features\n\n- A thing users can now do.\n' > "$notes"

key() { grep -E "^$1=" <<<"$2" | head -1 | cut -d= -f2-; }

# --- GitHub release ------------------------------------------------------------
: > "$CALL_LOG"
out=$(bash "$publish_sh" --repo "$gh_repo" --release v1.2.3 --notes-file "$notes")
[[ "$(key FORGE "$out")" == github ]] || fail "forge: $out"
[[ "$(key PUBLISHED "$out")" == release ]] || fail "published: $out"
[[ "$(key RELEASE_URL "$out")" == https://github.com/acme/widget/releases/tag/v1.2.3 ]] || fail "url: $out"
grep -qF "gh release create v1.2.3 --notes-file $notes --title v1.2.3" "$CALL_LOG" || fail "create call: $(cat "$CALL_LOG")"
grep -q -- '--generate-notes' "$CALL_LOG" && fail "generated notes passed"
ok "github: creates the release from the notes file and reads its URL back"

: > "$CALL_LOG"
bash "$publish_sh" --repo "$gh_repo" --release v1.2.3 --notes-file "$notes" --target 0123456789abcdef0123456789abcdef01234567 >/dev/null
grep -qF -- "--target 0123456789abcdef0123456789abcdef01234567" "$CALL_LOG" || fail "target: $(cat "$CALL_LOG")"
ok "github: passes --target through"

# --- GitLab release ------------------------------------------------------------
: > "$CALL_LOG"
out=$(bash "$publish_sh" --repo "$gl_repo" --release v1.2.3 --notes-file "$notes" --target abc123)
[[ "$(key FORGE "$out")" == gitlab ]] || fail "forge: $out"
[[ "$(key RELEASE_URL "$out")" == https://gitlab.example.com/acme/widget/-/releases/v1.2.3 ]] || fail "url: $out"
grep -qF "glab release create v1.2.3 --notes-file $notes --ref abc123" "$CALL_LOG" || fail "create call: $(cat "$CALL_LOG")"
ok "gitlab: creates with --ref and reads the URL from _links.self"

# --- GitHub dispatch -----------------------------------------------------------
: > "$CALL_LOG"
out=$(bash "$publish_sh" --repo "$gh_repo" --dispatch .github/workflows/release.yml --input level=minor --input channel=stable)
[[ "$(key PUBLISHED "$out")" == dispatch ]] || fail "published: $out"
[[ "$(key RUN_URL "$out")" == https://github.com/acme/widget/actions/runs/123456 ]] || fail "run url: $out"
grep -qF "gh workflow run .github/workflows/release.yml -f level=minor -f channel=stable" "$CALL_LOG" \
  || fail "dispatch call: $(cat "$CALL_LOG")"
ok "github: dispatches with each input under the caller's name, and reports the run"

: > "$CALL_LOG"
set +e
out=$(FAIL_ON="workflow run" bash "$publish_sh" --repo "$gh_repo" --dispatch release.yml --input bogus=minor)
rc=$?
set -e
[[ $rc -eq 70 ]] || fail "forge failure exit: $rc"
[[ "$(key PUBLISH_ERROR "$out")" == *"Unexpected inputs"* ]] || fail "error: $out"
[[ -z "$(key PUBLISHED "$out")" ]] || fail "a failed dispatch reported as published: $out"
ok "github: a rejected dispatch is a PUBLISH_ERROR, not a publish"

# --- refusals ------------------------------------------------------------------
expect_refusal() {
  local code="$1" what="$2"; shift 2
  : > "$CALL_LOG"
  set +e
  out=$(bash "$publish_sh" "$@")
  rc=$?
  set -e
  [[ $rc -eq $code ]] || fail "$what: exit $rc, wanted $code ($out)"
  [[ -n "$(key PUBLISH_ERROR "$out")" ]] || fail "$what: no PUBLISH_ERROR ($out)"
  [[ ! -s "$CALL_LOG" ]] || fail "$what: reached the forge: $(cat "$CALL_LOG")"
  ok "refuses: $what"
}

expect_refusal 69 "a dispatch on GitLab"          --repo "$gl_repo" --dispatch release.yml --input bump=minor
expect_refusal 64 "a release with no notes file"  --repo "$gh_repo" --release v1.2.3
expect_refusal 64 "a release with empty notes"    --repo "$gh_repo" --release v1.2.3 --notes-file /dev/null
expect_refusal 64 "a dispatch with no level"      --repo "$gh_repo" --dispatch release.yml
expect_refusal 64 "a malformed input"             --repo "$gh_repo" --dispatch release.yml --input minor
expect_refusal 64 "a pass-through flag"           --repo "$gh_repo" --release v1.2.3 --notes-file "$notes" --generate-notes
expect_refusal 64 "no mode"                       --repo "$gh_repo"

echo "PASS"
