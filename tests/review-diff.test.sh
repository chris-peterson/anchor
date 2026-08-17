#!/usr/bin/env bash
# Functional test for the review dispatcher (scripts/review-diff.sh) and its
# backend adapters (scripts/review/{moor,revdiff}.sh).
#
# Drives the real dispatcher against stub backends: a stub `moor` (files mode)
# and a fake git difftool (range mode) that write a fixture sidecar, and a stub
# `revdiff` that writes fixture markdown and exits with a chosen code. Asserts
# the normalized DIFF contract each adapter emits. Requires jq.
set -euo pipefail

# Hermetic: ignore the user's global/system git config so backend selection is
# controlled per-case here, not by a global anchor.reviewBackend.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dispatch="$here/../scripts/review-diff.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-review-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub launch-revdiff.sh: the adapter delegates terminal launching to the
# revdiff plugin's launcher (annotations on stdout, exit 0/10/other). This stub
# stands in via ANCHOR_REVDIFF_LAUNCHER: prints $REVDIFF_STUB_OUTPUT, exits
# $REVDIFF_STUB_RC, records its args to $REVDIFF_ARGS_FILE.
cat > "$bin/stub-launch-revdiff.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${REVDIFF_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$REVDIFF_ARGS_FILE"
printf '%s' "${REVDIFF_STUB_OUTPUT:-}"
exit "${REVDIFF_STUB_RC:-0}"
EOF
chmod +x "$bin/stub-launch-revdiff.sh"
export ANCHOR_REVDIFF_LAUNCHER="$bin/stub-launch-revdiff.sh"

# --- fake git difftool: captures the adapter's input sidecar (for asserting the
# seeded header), then copies $MOOR_FIXTURE into the sidecar named by REVIEW_CONTEXT
cat > "$bin/fake-difftool.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${MOOR_INPUT_CAPTURE:-}" ] && [ -n "${REVIEW_CONTEXT:-}" ] && cp "$REVIEW_CONTEXT" "$MOOR_INPUT_CAPTURE" 2>/dev/null
if [ -n "${MOOR_FIXTURE:-}" ] && [ -n "${REVIEW_CONTEXT:-}" ]; then
  cat "$MOOR_FIXTURE" > "$REVIEW_CONTEXT"
fi
exit 0
EOF
chmod +x "$bin/fake-difftool.sh"

# --- stub moor (files mode): writes $MOOR_FIXTURE into the --context sidecar
cat > "$bin/moor" <<'EOF'
#!/usr/bin/env bash
ctx=""
while [ $# -gt 0 ]; do case "$1" in --context) ctx="$2"; shift 2;; *) shift;; esac; done
[ -n "${MOOR_FIXTURE:-}" ] && [ -n "$ctx" ] && cat "$MOOR_FIXTURE" > "$ctx"
exit 0
EOF
chmod +x "$bin/moor"

# --- stub revdiff: never executed (the adapter drives the launcher), but the
# resolver looks the tool up on PATH, so the suite has to carry one to test
# against a machine that has revdiff rather than whatever the host happens to
# have installed.
printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/revdiff"
chmod +x "$bin/revdiff"

export PATH="$bin:$PATH"

# --- a git repo with a HEAD~1...HEAD diff to review -------------------------
repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email "t@example.com"
git -C "$repo" config user.name "T"
git -C "$repo" config commit.gpgsign false
git -C "$repo" config diff.tool faketool
git -C "$repo" config difftool.faketool.cmd "$bin/fake-difftool.sh"
printf 'one\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m first
printf 'one\ntwo\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m second

run() { ( cd "$repo" && bash "$dispatch" "$@" ); }
verdict_of() { sed -n 's/^REVIEW_VERDICT=//p' <<<"$1"; }
json_of()    { sed -n 's/^REVIEW_OUTPUT=//p' <<<"$1"; }

# Write a moor sidecar fixture and point MOOR_FIXTURE at it, which is what both
# stubs above read. Exporting inside the helper keeps the call sites a bare
# `mkfix '<json>'` rather than an `export VAR="$(mkfix ...)"` that masks its
# return value (SC2155).
mkfix() { printf '%s' "$1" > "$work/fixture.json"; MOOR_FIXTURE="$work/fixture.json"; export MOOR_FIXTURE; }

# ============================ moor adapter ================================
# (exercised through files mode via the stub moor)
git -C "$repo" config anchor.reviewBackend moor

# approved + complete
mkfix '{"output":{"exitCode":0,"reviewer":"Rev","comments":[]}}'
o=$(run --files "$repo/a.txt" "$repo/a.txt")
[ "$(verdict_of "$o")" = approved ] || fail "moor exit0 -> $(verdict_of "$o"), want approved"
j=$(json_of "$o")
[ "$(jq -r .backend <<<"$j")" = moor ]              || fail "moor backend"
[ "$(jq -r .reviewCompleteness <<<"$j")" = complete ] || fail "moor exit0 completeness"
[ "$(jq -r 'has("severitySource")' <<<"$j")" = false ] || fail "moor still emits severitySource"
[ "$(jq -r '.capabilities | has("gradedSeverity")' <<<"$j")" = false ] || fail "moor still emits caps.gradedSeverity"
ok "moor: exit 0 -> approved, complete, ungraded"

# changes-requested with a mapped line comment. The fixture carries a stray
# `action` the way an older moor would; the mapping drops it (moor IM.OUT-02a).
mkfix '{"output":{"exitCode":1,"reviewer":"Rev","comments":[{"body":"fix this","action":"fix-now","file":"a.txt","startLine":2,"endLine":2}]}}'
o=$(run --files "$repo/a.txt" "$repo/a.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ] || fail "moor exit1 verdict"
[ "$(jq -r '.comments[0] | has("action")' <<<"$j")" = false ] || fail "moor comment still carries action"
[ "$(jq -r '.comments[0].target' <<<"$j")" = line ]    || fail "moor comment target=line"
[ "$(jq -r '.comments[0].startLine' <<<"$j")" = 2 ]    || fail "moor comment startLine"
[ "$(jq -r '.comments[0].side' <<<"$j")" = new ]       || fail "moor comment side=new"
ok "moor: exit 1 -> changes-requested + line comment mapped"

# incomplete + partial
mkfix '{"output":{"exitCode":2,"reviewer":"Rev","comments":[]}}'
o=$(run --files "$repo/a.txt" "$repo/a.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = incomplete ] || fail "moor exit2 verdict"
[ "$(jq -r .reviewCompleteness <<<"$j")" = partial ] || fail "moor exit2 completeness=partial"
ok "moor: exit 2 -> incomplete, partial"

# edited commit message -> editedFields
mkfix '{"output":{"exitCode":0,"reviewer":"Rev","comments":[],"commitMessage":{"original":"old subj","edited":"new subj"}}}'
o=$(run --files "$repo/a.txt" "$repo/a.txt"); j=$(json_of "$o")
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = commit-message ] || fail "moor editedFields target"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "new subj" ]      || fail "moor editedFields edited"
ok "moor: edited commit message -> editedFields[commit-message]"

# range mode through the fake difftool (backend=moor when the sidecar has output)
mkfix '{"output":{"exitCode":0,"reviewer":"Rev","comments":[]}}'
o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]     || fail "moor range verdict"
[ "$(jq -r .backend <<<"$j")" = moor ]  || fail "moor range backend"
ok "moor: range mode (difftool with sidecar output) -> approved"

# --message-file seeds the drafted commit message into the review input header
printf 'wip line\n' >> "$repo/a.txt"
msg="$work/msg.txt"; printf 'Add a feature\n\nThe body explains why.\n' > "$msg"
mkfix '{"output":{"exitCode":0,"reviewer":"Rev","comments":[]}}'
export MOOR_INPUT_CAPTURE="$work/input.json"
o=$(run --local --message-file "$msg")
[ "$(verdict_of "$o")" = approved ] || fail "message-file review verdict"
[ "$(jq -r '.input.title' "$MOOR_INPUT_CAPTURE")" = "Add a feature" ] \
  || fail "subject not seeded as title: $(jq -c .input.title "$MOOR_INPUT_CAPTURE")"
[ "$(jq -r '.input.details[] | select(.label=="body") | .value' "$MOOR_INPUT_CAPTURE")" = "The body explains why." ] \
  || fail "body not seeded as a body row"
unset MOOR_INPUT_CAPTURE
ok "moor: --message-file seeds subject as title and body as a body row"

# difftool fallback: sidecar left with no output section -> no-verdict/difftool
unset MOOR_FIXTURE
o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]        || fail "fallback verdict"
[ "$(jq -r .backend <<<"$j")" = difftool ]   || fail "fallback backend=difftool"
[ "$(jq -r .capabilities.producesVerdict <<<"$j")" = false ] || fail "fallback producesVerdict=false"
[ "$(jq -r .raw.exitCode <<<"$j")" = absent ] || fail "fallback raw.exitCode=absent"
ok "moor: no sidecar output -> no-verdict, backend=difftool"

# ============================ revdiff adapter =============================
git -C "$repo" config anchor.reviewBackend revdiff

# rc 0, no annotations -> approved, no comments, completeness null
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]                 || fail "revdiff rc0 verdict"
[ "$(jq -r .backend <<<"$j")" = revdiff ]           || fail "revdiff backend"
[ "$(jq '.comments|length' <<<"$j")" = 0 ]          || fail "revdiff rc0 no comments"
[ "$(jq -r .reviewCompleteness <<<"$j")" = null ]   || fail "revdiff completeness=null"
[ "$(jq -r 'has("severitySource")' <<<"$j")" = false ] || fail "revdiff still emits severitySource"
[ "$(jq -r .capabilities.sideMarkers <<<"$j")" = true ] || fail "revdiff caps.sideMarkers"
ok "revdiff: rc 0 -> approved, no comments, completeness null"

# rc 10 with a line annotation and a file-level annotation
md=$'## a.txt:2 (+)\nuse a constant here\n\n## a.txt (file-level)\nsplit this file'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ]        || fail "revdiff rc10 verdict"
[ "$(jq '.comments|length' <<<"$j")" = 2 ]          || fail "revdiff parsed 2 comments, got $(jq '.comments|length' <<<"$j")"
[ "$(jq -r '.comments[0].target' <<<"$j")" = line ] || fail "revdiff comment0 target=line"
[ "$(jq -r '.comments[0].startLine' <<<"$j")" = 2 ] || fail "revdiff comment0 startLine=2"
[ "$(jq -r '.comments[0].side' <<<"$j")" = new ]    || fail "revdiff comment0 side=new (+)"
[ "$(jq -r '.comments[0] | has("action")' <<<"$j")" = false ] || fail "revdiff comment0 still carries action"
[ "$(jq -r '.comments[0].body' <<<"$j")" = "use a constant here" ] || fail "revdiff comment0 body"
[ "$(jq -r '.comments[1].target' <<<"$j")" = file ] || fail "revdiff comment1 target=file"
[ "$(jq -r '.comments[1].file' <<<"$j")" = a.txt ]  || fail "revdiff comment1 file"
ok "revdiff: rc 10 -> changes-requested + line and file-level comments parsed"

# removed-side marker (-)
md=$'## a.txt:2 (-)\nthis deletion looks wrong'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(run --previous); j=$(json_of "$o")
[ "$(jq -r '.comments[0].side' <<<"$j")" = old ] || fail "revdiff (-) -> side=old"
ok "revdiff: (-) marker -> side=old"

# (description) echo block is dropped (round-trip not consumed yet), so an
# exit-10 whose only annotation is the seeded description reads as approved
md=$'## (description) (file-level)\n# subject\n\n- body: seeded message'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]        || fail "description-only -> approved, got $(verdict_of "$o")"
[ "$(jq '.comments|length' <<<"$j")" = 0 ] || fail "(description) block should be dropped from comments"
ok "revdiff: (description) echo dropped -> approved, no comments"

# a real comment alongside a (description) block survives -> changes-requested
md=$'## (description) (file-level)\nseeded msg\n\n## a.txt:2 (+)\nfix this'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ]       || fail "real comment + description -> changes-requested"
[ "$(jq '.comments|length' <<<"$j")" = 1 ]         || fail "keep the 1 real comment, drop description"
[ "$(jq -r '.comments[0].file' <<<"$j")" = a.txt ] || fail "surviving comment should be the real one"
ok "revdiff: real comment kept, (description) dropped -> changes-requested"

# rc 1 -> no-verdict (tool error)
export REVDIFF_STUB_RC=1 REVDIFF_STUB_OUTPUT=""; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]        || fail "revdiff rc1 verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = 1 ]     || fail "revdiff rc1 raw.exitCode"
ok "revdiff: rc 1 -> no-verdict (error)"

# launcher not found -> no-verdict, producesVerdict false
export ANCHOR_REVDIFF_LAUNCHER="$work/nonexistent-launcher"; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]                         || fail "missing-launcher verdict"
[ "$(jq -r .capabilities.producesVerdict <<<"$j")" = false ] || fail "missing-launcher producesVerdict"
ok "revdiff: launcher not found -> no-verdict, producesVerdict false"
export ANCHOR_REVDIFF_LAUNCHER="$bin/stub-launch-revdiff.sh"   # restore

# ref translation: --previous (HEAD~1...HEAD) -> revdiff base HEAD~1 against HEAD
export REVDIFF_ARGS_FILE="$work/args.txt"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""; o=$(run --previous)
grep -qx 'HEAD~1' "$REVDIFF_ARGS_FILE" || fail "revdiff args missing base HEAD~1: $(cat "$REVDIFF_ARGS_FILE")"
grep -qx 'HEAD'   "$REVDIFF_ARGS_FILE" || fail "revdiff args missing against HEAD"
unset REVDIFF_ARGS_FILE
ok "revdiff: --previous translated to base/against refs"

# ============================ backend selection ==========================
git -C "$repo" config --unset anchor.reviewBackend
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(run --previous); j=$(json_of "$o")
[ "$(jq -r .backend <<<"$j")" = revdiff ] || fail "default backend should be revdiff"
ok "backend: defaults to revdiff when anchor.reviewBackend is unset"

git -C "$repo" config anchor.reviewBackend bogus
if run --previous 2>/dev/null; then fail "unknown backend should exit non-zero"; fi
ok "backend: unknown backend exits non-zero"
git -C "$repo" config --unset anchor.reviewBackend

# ================== backend resolution against installed tools ============
# The resolver only considers tools that are there, so these run under a PATH
# built for the case: a system PATH carries neither viewer, and `only` carries
# moor alone.
only="$work/only"; mkdir -p "$only"
printf '#!/usr/bin/env bash\nexit 0\n' > "$only/moor"; chmod +x "$only/moor"
system_path="/usr/bin:/bin"

pb() { ( cd "$repo" && PATH="$1" bash "$dispatch" --print-backend ); }

o=$(pb "$bin:$PATH")
grep -qx 'REVIEW_BACKEND=revdiff' <<<"$o" || fail "revdiff installed -> want revdiff, got: $o"
ok "backend: prefers revdiff when its tool is installed"

o=$(pb "$only:$system_path")
grep -qx 'REVIEW_BACKEND=moor' <<<"$o" || fail "revdiff absent -> want moor, got: $o"
ok "backend: substitutes an installed viewer when the preferred tool is absent"

# With nothing to stand in, the probe still names what was asked for — the
# degradation below is the run's business, not a claim that moor is installed.
o=$(pb "$system_path")
grep -qx 'REVIEW_BACKEND=revdiff' <<<"$o"     || fail "no viewer -> want the configured name, got: $o"
grep -qx 'REVIEW_BACKEND_AVAILABLE=0' <<<"$o" || fail "no viewer -> want AVAILABLE=0, got: $o"
ok "backend: with nothing installed the probe reports the preference, unavailable"

# The run keeps the configured adapter, whose report names the tool that is
# missing. It does not slide into git's difftool: `diff.tool` is set here, so
# the only thing stopping that is the rule, and a difftool review would report
# `difftool` / no-verdict having shown a diff nobody can grade — the rung the
# skill's fallback ladder replaced.
unset MOOR_FIXTURE
o=$( cd "$repo" && PATH="$system_path" bash "$dispatch" --previous )
[ "$(jq -r .backend <<<"$(json_of "$o")")" = revdiff ] \
  || fail "no viewer -> want the configured adapter, got: $(json_of "$o")"
ok "backend: no viewer installed keeps the configured adapter, never a difftool"

# `git` is not a backend at all (DIFF-18): a changeset shown without a verdict
# invites "you saw it, approve?", so the difftool is off the menu entirely and
# asking for it fails the same way any other typo does.
git -C "$repo" config anchor.reviewBackend git
rc=0
o=$( cd "$repo" && PATH="$system_path" bash "$dispatch" --previous 2>&1 ) || rc=$?
[ "$rc" -eq 64 ] || fail "git backend -> want exit 64 for an unknown backend, got $rc: $o"
grep -q "unknown review backend 'git'" <<<"$o" \
  || fail "git backend -> want the unknown-backend error naming it, got: $o"
! grep -q 'REVIEW_VERDICT=' <<<"$o" || fail "git backend -> nothing should be reviewed, got: $o"
git -C "$repo" config --unset anchor.reviewBackend
ok "backend: git is not selectable — the difftool is off the menu (DIFF-18)"

# editor is selectable but never substituted in, so an absent viewer doesn't
# turn a changeset review into an editor buffer.
git -C "$repo" config anchor.reviewBackend editor
o=$(pb "$system_path")
grep -qx 'REVIEW_BACKEND=editor' <<<"$o" || fail "editor configured -> want editor, got: $o"
git -C "$repo" config --unset anchor.reviewBackend
ok "backend: editor stays selected and is never substituted in"

# ================== context flags anywhere in the argv ====================
# `--repo` used to be leading-only, so an invocation that appended it reviewed
# the cwd repo instead of the target — and `--local` staged the cwd repo too.
# `other` stands in for the session's cwd: a clean checkout whose own diff is
# empty, which is what made the wrong-repo review look like an approved one.
other="$work/other"
git init --quiet -b main "$other"
git -C "$other" config user.email "t@example.com"
git -C "$other" config user.name "T"
git -C "$other" config commit.gpgsign false
printf 'untouched\n' > "$other/b.txt"; git -C "$other" add -A; git -C "$other" commit --quiet -m only

git -C "$repo" config anchor.reviewBackend moor
mkfix '{"output":{"exitCode":0,"reviewer":"Rev","comments":[]}}'
export MOOR_INPUT_CAPTURE="$work/input.json"
o=$( cd "$other" && bash "$dispatch" --previous --repo "$repo" )
[ "$(verdict_of "$o")" = approved ] || fail "trailing --repo -> $(verdict_of "$o"), want approved"
[ "$(jq -r '.input.details[] | select(.label=="repo") | .value' "$MOOR_INPUT_CAPTURE")" = repo ] \
  || fail "trailing --repo reviewed the wrong checkout: $(jq -c '.input.details' "$MOOR_INPUT_CAPTURE")"
unset MOOR_INPUT_CAPTURE
ok "context: --repo after the mode retargets the review (TARGET-10)"

# a value that looks like a context flag stays a value
o=$( cd "$other" && bash "$dispatch" --previous --repo "$repo" --title '--worktree' )
[ "$(verdict_of "$o")" = approved ] || fail "--title '--worktree' should stay a title value: $o"
ok "context: a flag-shaped option value is not read as a context flag"

# per-skill backend selection still resolves when --skill trails the mode
git -C "$repo" config anchor.trailing.reviewBackend revdiff
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$( cd "$other" && bash "$dispatch" --previous --repo "$repo" --skill trailing )
[ "$(jq -r .backend <<<"$(json_of "$o")")" = revdiff ] \
  || fail "trailing --skill did not select the per-skill backend: $(json_of "$o")"
git -C "$repo" config --unset anchor.trailing.reviewBackend
ok "context: --skill after the mode still selects the per-skill backend"

# a misspelled flag is an error, not a silently dropped argument
rc=0; o=$( cd "$repo" && bash "$dispatch" --previous --repoo "$repo" 2>&1 ) || rc=$?
[ "$rc" -eq 64 ] || fail "unknown option -> want exit 64, got $rc: $o"
! grep -q 'REVIEW_VERDICT=' <<<"$o" || fail "unknown option should review nothing: $o"
ok "context: an unknown option exits 64 instead of being dropped"

rc=0; o=$( cd "$repo" && bash "$dispatch" --previous HEAD~1...HEAD 2>&1 ) || rc=$?
[ "$rc" -eq 64 ] || fail "extra positional -> want exit 64, got $rc: $o"
ok "context: an extra positional argument exits 64"

# ================== empty range ==========================================
# Nothing to show means nothing was reviewed, and a viewer quit on an empty diff
# is indistinguishable from an approval — so the dispatcher never launches one.
git -C "$repo" config anchor.reviewBackend revdiff
export REVDIFF_ARGS_FILE="$work/empty-args.txt"; rm -f "$REVDIFF_ARGS_FILE"
o=$( cd "$other" && bash "$dispatch" --local 2>/dev/null ); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "empty range -> $(verdict_of "$o"), want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = empty-range ] || fail "empty range raw.exitCode: $j"
[ "$(jq -r .capabilities.producesVerdict <<<"$j")" = false ] || fail "empty range producesVerdict"
[ ! -e "$REVDIFF_ARGS_FILE" ] || fail "empty range should not launch a viewer"
unset REVDIFF_ARGS_FILE
ok "empty range: no-verdict, nothing launched (DIFF-21)"

echo "# all checks passed"
