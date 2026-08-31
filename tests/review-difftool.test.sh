#!/usr/bin/env bash
# Functional test for the difftool backend (scripts/review/backends/difftool.sh)
# and the `diff.tool` fall-through the dispatcher resolves for it.
#
# Drives the real dispatcher with ANCHOR_SPLIT_RUNNER pointed at a stub that
# stands in for the terminal a difftool renders in: it runs the command it was
# handed, so `git difftool` really launches, with a `difftool.<name>.cmd` that
# stands in for the reviewer — reading the diff, or writing into the working tree
# the way a reviewer edits in place. Asserts that what they wrote comes back as
# feedback, and that a review they only read comes back approved. Requires jq.
set -euo pipefail

# Hermetic: ignore the user's global/system git config so backend selection is
# controlled per-case here, not by their own diff.tool.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dispatch="$here/../scripts/review-diff.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-difftool-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"; mkdir -p "$bin"

# The terminal stand-in: run the command here rather than in a pane, and report
# its status the way a real split would.
cat > "$bin/stub-split-runner.sh" <<'EOF'
#!/usr/bin/env bash
sh -c "$1"
EOF
chmod +x "$bin/stub-split-runner.sh"
export ANCHOR_SPLIT_RUNNER="$bin/stub-split-runner.sh"

# The reviewer stand-in, run by git as the difftool. READ leaves both sides
# alone; WRITE appends to the right-hand side, which --dir-diff has symlinked to
# the working-tree file, so the edit lands where a reviewer's would.
#   DIFFTOOL_STUB_MODE=read   (default)
#   DIFFTOOL_STUB_MODE=write  append $DIFFTOOL_STUB_TEXT to $2
#   DIFFTOOL_STUB_RC          the status it leaves with (default 0)
cat > "$bin/stub-difftool.sh" <<'EOF'
#!/usr/bin/env bash
# $2 is the right-hand side, which --dir-diff makes a *directory* of symlinks
# into the working tree and --no-index makes a single file. Appending through
# either reaches the real file, which is what a reviewer editing in place does.
if [ "${DIFFTOOL_STUB_MODE:-read}" = write ]; then
  if [ -d "$2" ]; then
    find "$2" -type l -o -type f | while IFS= read -r f; do
      printf '%s\n' "${DIFFTOOL_STUB_TEXT:-# TODO: why?}" >> "$f"
    done
  else
    printf '%s\n' "${DIFFTOOL_STUB_TEXT:-# TODO: why?}" >> "$2"
  fi
fi
exit "${DIFFTOOL_STUB_RC:-0}"
EOF
chmod +x "$bin/stub-difftool.sh"

# --- a repo with a changeset to review --------------------------------------
repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email "t@example.com"
git -C "$repo" config user.name "T"
git -C "$repo" config commit.gpgsign false
printf 'one\n' > "$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m first
printf 'one\ntwo\n' > "$repo/a.txt"

# The tool is git's to launch, named by a cmd rather than a binary on PATH —
# which is the case a difftool has to answer for and a viewer never does.
git -C "$repo" config difftool.stubtool.cmd "$bin/stub-difftool.sh \"\$LOCAL\" \"\$REMOTE\""
git -C "$repo" config difftool.prompt false

run() { ( cd "$repo" && PATH="$bin:$PATH" bash "$dispatch" "$@" ); }
key_of()     { sed -n "s/^$1=//p" <<<"$2"; }
verdict_of() { sed -n 's/^REVIEW_VERDICT=//p' <<<"$1"; }
json_of()    { sed -n 's/^REVIEW_OUTPUT=//p' <<<"$1"; }

# --- diff.tool is honored, the way core.editor is for edit mode -------------
git -C "$repo" config diff.tool stubtool
o=$(run --skill commit --probe)
[ "$(key_of REVIEW_MODE "$o")" = diff ]         || fail "a git range is still a diff subject"
[ "$(key_of REVIEW_BACKEND "$o")" = stubtool ]  || fail "diff.tool should be what opens, got $(key_of REVIEW_BACKEND "$o")"
[ "$(key_of REVIEW_BACKEND_SOURCE "$o")" = config ] || fail "a configured diff.tool is the user's choice"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 1 ]       || fail "git can launch it, so it is available"
ok "difftool: diff.tool is honored as diff mode's backend"

# anchor.diff.backend still outranks it — the narrower statement wins.
git -C "$repo" config anchor.diff.backend revdiff
o=$(run --skill commit --probe)
[ "$(key_of REVIEW_BACKEND "$o")" = revdiff ] || fail "anchor.diff.backend should outrank diff.tool"
git -C "$repo" config --unset anchor.diff.backend || true
ok "difftool: anchor.diff.backend outranks diff.tool"

# --- read it, change nothing -> approved ------------------------------------
export DIFFTOOL_STUB_MODE=read
o=$(run --skill commit --local --path a.txt); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]            || fail "read-only -> $(verdict_of "$o"), want approved"
[ "$(jq -r .mode <<<"$j")" = diff ]            || fail "mode should be diff"
[ "$(jq -r .backend <<<"$j")" = stubtool ]     || fail "backend should name the tool"
[ "$(jq '.comments|length' <<<"$j")" = 0 ]     || fail "nothing was written, so there is nothing to say"
ok "difftool: a review the reviewer only read -> approved"

# --- edit in place -> the edits come back as the feedback -------------------
export DIFFTOOL_STUB_MODE=write DIFFTOOL_STUB_TEXT='# TODO: is two enough?'
o=$(run --skill commit --local --path a.txt); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ] \
  || fail "an edited tree -> $(verdict_of "$o"), want changes-requested"
[ "$(jq '.comments|length' <<<"$j")" = 1 ]     || fail "one file was edited, so one comment"
[ "$(jq -r '.comments[0].file' <<<"$j")" = a.txt ] || fail "the comment should name the file edited"
[ "$(jq -r '.comments[0].target' <<<"$j")" = file ] || fail "an edit is anchored to its file"
grep -q 'TODO: is two enough' <<<"$(jq -r '.comments[0].raw' <<<"$j")" \
  || fail "the reviewer's own text should ride back verbatim: $(jq -c '.comments[0].raw' <<<"$j")"
ok "difftool: an edit in place comes back as feedback naming the file"

# The edit is in the working tree, which is the point — the skill re-reads it.
grep -q 'TODO: is two enough' "$repo/a.txt" || fail "the reviewer's edit should be in the working tree"
ok "difftool: the reviewer's edit lands in the file, not a temp copy"

# --- the tool's own status is not its verdict; the tree is ------------------
# git difftool ignores what the tool returns unless --trust-exit-code, and plenty
# of tools use non-zero for "the files differ". So a tool that exits 3 having
# written nothing is a reviewer who read and left, not a failure.
printf 'one\ntwo\n' > "$repo/a.txt"
export DIFFTOOL_STUB_MODE=read DIFFTOOL_STUB_RC=3
o=$(run --skill commit --local --path a.txt)
[ "$(verdict_of "$o")" = approved ] \
  || fail "a tool's own status should not override the tree, got $(verdict_of "$o")"
unset DIFFTOOL_STUB_RC
ok "difftool: the tool's own exit status is not the verdict — the tree is"

# --- a name git cannot launch is reported, not opened -----------------------
git -C "$repo" config diff.tool definitely-not-a-tool
export DIFFTOOL_STUB_MODE=read
o=$(run --skill commit --local --path a.txt 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "an unlaunchable tool -> want no-verdict"
ok "difftool: a diff.tool git cannot launch reports rather than opening"

echo "# all checks passed"
