#!/usr/bin/env bash
# Functional test: the /anchor:commit flow on paths that start with punctuation.
#
# Every helper scopes git to the caller's repo-root-relative paths. Built as the
# short magic form `:/<path>`, git reads the characters after the `:` as magic
# signatures, and it reserves ASCII punctuation for magic it hasn't defined, so a
# docsify `_sidebar.md` was fatal — "Unimplemented pathspec magic '_'", exit 128
# — at the first helper that touched it. This drives the three scripts the flow
# runs (commit-preflight.sh, review-diff.sh --local, commit.sh) end to end on
# `_sidebar.md` and two other punctuation-led names, against a fixture repo with
# a local bare remote, plus a bracketed name that must match only itself.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/../scripts"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-pathspec-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"

# --- a review host that approves --------------------------------------------
# review-diff.sh hands revdiff's command string to ANCHOR_HOST_RUNNER. This one
# leaves a note on the context file's `ZZ` row, as a reviewer choosing it
# does.
bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/approve-runner.sh" <<'EOF'
#!/usr/bin/env bash
cmd=${1% 2>*}
eval "set -- $cmd"
while [[ "$1" == REVDIFF_*=* ]]; do shift; done
shift
out=""
for a in "$@"; do case "$a" in --output=*) out="${a#*=}" ;; esac; done
n=$(grep -n -F -- '│ `ZZ`' "$(git rev-parse --show-toplevel)/(context).md" | head -1 | cut -d: -f1)
[ -n "$n" ] || exit 1
printf '## (context).md:%s (+)\naccept' "$n" > "$out"
exit 10
EOF
chmod +x "$bin/approve-runner.sh"
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "version: v1.14.0"; exit 0; }
exit 0
EOF
chmod +x "$bin/revdiff"
export PATH="$bin:$PATH" ANCHOR_HOST_RUNNER="$bin/approve-runner.sh"

# --- fixture: a docsify site on a feature branch ------------------------------
remote="$work/remote.git"; repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false
printf '# Home\n' > "$repo/README.md"
printf -- '- [Home](/)\n' > "$repo/_sidebar.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m seed
git init --quiet --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push --quiet -u origin main
git -C "$repo" remote set-head origin main
git -C "$repo" checkout --quiet -b docs

printf -- '- [Home](/)\n- [Guides](guides.md)\n' > "$repo/_sidebar.md"
printf 'dash\n'     > "$repo/-dash.md"
printf 'bang\n'     > "$repo/!bang.md"
printf 'bracket\n'  > "$repo/[id].md"
# Matched by `[id].md` as a glob; named by no one, so it must stay out.
printf 'not mine\n' > "$repo/i.md"

named=(_sidebar.md -dash.md '!bang.md' '[id].md')
path_args=()
for p in "${named[@]}"; do path_args+=(--path "$p"); done
expected=$(printf '%s\n' "${named[@]}" | LC_ALL=C sort)

# Run from a subdirectory: the paths are root-relative wherever the caller is.
mkdir -p "$repo/guides"
run() { ( cd "$repo/guides" && "$@" ); }
staged() { git -C "$repo" diff --cached --name-only | LC_ALL=C sort; }

# --- commit-preflight.sh ------------------------------------------------------
rc=0; o=$(run bash "$scripts/commit-preflight.sh" "${path_args[@]}" 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "commit-preflight.sh exited $rc: $o"
[ "$(val STAGED "$o")" = 1 ] || fail "STAGED should be 1: $o"
[ "$(val STAT "$o")" = "4 files changed, 4 insertions(+)" ] || fail "STAT should cover the four named paths: $o"
[ "$(staged)" = "$expected" ] || fail "preflight should stage exactly the named paths, staged: $(staged | tr '\n' ' ')"
[ "$(val OTHER_STAGED "$o")" = 0 ] || fail "OTHER_STAGED should be 0: $o"
ok "commit-preflight.sh stages _sidebar.md, -dash.md, !bang.md, and [id].md, and not i.md"

# --- review-diff.sh --local --probe -------------------------------------------
rc=0; o=$(run bash "$scripts/review-diff.sh" --skill commit --probe --local "${path_args[@]}" 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "review-diff.sh --probe exited $rc: $o"
[ "$(val REVIEW_AVAILABLE "$o")" = 1 ] || fail "the probe should find a review to open: $o"
ok "review-diff.sh --local --probe answers for the punctuation-led paths"

# --- review-diff.sh --local: the launch restages and scopes the diff -----------
msg="$work/msg.txt"
printf 'Add the guides page to the sidebar\n' > "$msg"
rc=0; o=$(run bash "$scripts/review-diff.sh" --skill commit --local --message-file "$msg" "${path_args[@]}" 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "review-diff.sh --local exited $rc: $o"
[ "$(val REVIEW_VERDICT "$o")" = approved ] || fail "the stub approves: $o"
index=$(val REVIEW_INDEX "$o")
[ -n "$index" ] || fail "the review should print REVIEW_INDEX: $o"
[ "$(staged)" = "$expected" ] || fail "the review should leave exactly the named paths staged, staged: $(staged | tr '\n' ' ')"
ok "review-diff.sh --local opens on the punctuation-led paths and prints REVIEW_INDEX"

# --- commit.sh ----------------------------------------------------------------
rc=0; o=$(run bash "$scripts/commit.sh" --mode new --message-file "$msg" \
          --reviewed-index "$index" "${path_args[@]}" 2>&1) || rc=$?
[ "$rc" = 0 ] || fail "commit.sh exited $rc: $o"
grep -qx 'PUSHED=ok' <<<"$o" || fail "commit.sh should push: $o"
got=$(git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD | LC_ALL=C sort)
[ "$got" = "$expected" ] || fail "the commit should carry exactly the named paths, got: $(tr '\n' ' ' <<<"$got")"
[ "$(git -C "$remote" rev-parse docs)" = "$(git -C "$repo" rev-parse HEAD)" ] || fail "the commit should be on origin/docs"
git -C "$repo" status --porcelain -- i.md | grep -q '^?? ' || fail "i.md should be left untracked"
ok "commit.sh commits and pushes exactly the punctuation-led paths"
