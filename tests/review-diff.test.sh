#!/usr/bin/env bash
# Functional test for the review dispatcher (scripts/review-diff.sh) and its
# revdiff adapter (scripts/review/revdiff.sh).
#
# Drives the real dispatcher against a stub revdiff launcher that writes fixture
# markdown and exits with a chosen code. Asserts the normalized DIFF contract
# the adapter emits, plus the dispatcher's own range, header, staging, and
# tool-resolution behavior. Requires jq.
set -euo pipefail

# Hermetic: ignore the user's global/system git config so tool selection is
# controlled per-case here, not by a global anchor.diff.tool.
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

# --- stub split runner: the adapter builds revdiff's command string and hands
# it to scripts/lib/review-host.sh, which opens it in a pane. This stub stands in
# via ANCHOR_HOST_RUNNER, so the suite drives the real command string rather
# than a launcher's argv: it unpacks the string back into an argv, records it to
# $REVDIFF_ARGS_FILE, copies the seeded header (--description-file, which the
# adapter deletes on return) to $REVDIFF_DESC_CAPTURE, writes
# $REVDIFF_STUB_OUTPUT to the --output file the adapter named, and exits
# $REVDIFF_STUB_RC.
cat > "$bin/stub-host-runner.sh" <<'EOF'
#!/usr/bin/env bash
cmd=${1#REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true }
cmd=${cmd% 2>*}
eval "set -- $cmd"
shift   # the revdiff binary itself
[ -n "${REVDIFF_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$REVDIFF_ARGS_FILE"
out=""
for a in "$@"; do
  case "$a" in
    --output=*) out="${a#*=}" ;;
    --description-file=*)
      [ -n "${REVDIFF_DESC_CAPTURE:-}" ] && cp "${a#*=}" "$REVDIFF_DESC_CAPTURE" ;;
  esac
done
[ -n "$out" ] && printf '%s' "${REVDIFF_STUB_OUTPUT:-}" > "$out"
exit "${REVDIFF_STUB_RC:-0}"
EOF
chmod +x "$bin/stub-host-runner.sh"
export ANCHOR_HOST_RUNNER="$bin/stub-host-runner.sh"

# --- stub revdiff: never executed (the stub runner intercepts the command), but
# the adapter resolves the tool on PATH before building it, so the suite has to
# carry one to test against a machine that has revdiff rather than whatever the
# host happens to have installed.
printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/revdiff"
chmod +x "$bin/revdiff"

export PATH="$bin:$PATH"

# --- a git repo with a HEAD~1...HEAD diff to review -------------------------
repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email "t@example.com"
git -C "$repo" config user.name "T"
git -C "$repo" config commit.gpgsign false
# Nothing assumes a viewer, so the suite names the one it exercises. A hermetic
# repo with this unset is the `no-tool` case, which has its own coverage below.
git -C "$repo" config anchor.diff.tool revdiff
printf 'one\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m first
printf 'one\ntwo\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m second

run() { ( cd "$repo" && bash "$dispatch" "$@" ); }
verdict_of() { sed -n 's/^REVIEW_VERDICT=//p' <<<"$1"; }
json_of()    { sed -n 's/^REVIEW_OUTPUT=//p' <<<"$1"; }

# ============================ revdiff adapter =============================

# rc 0, no annotations -> approved, no comments, completeness null
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""; o=$(run --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]                 || fail "revdiff rc0 verdict"
[ "$(jq -r .tool <<<"$j")" = revdiff ]           || fail "revdiff tool"
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

# The pane went away before revdiff could report — closing it rather than
# quitting the review. Named, not numbered: the split runner's status is not one
# revdiff returned, and the remedy is to open it again rather than to walk the
# fallback ladder.
export REVDIFF_STUB_RC=124 REVDIFF_STUB_OUTPUT=""
o=$(run --previous 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]                        || fail "a closed pane -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = pane-closed ]           || fail "raw.exitCode should name the cause, got $(jq -c .raw <<<"$j")"
[ "$(jq -r .capabilities.producesVerdict <<<"$j")" = false ] || fail "a pane that never reported graded nothing"
grep -q 'quit the review to finish it' "$work/err.txt"       || fail "the remedy should reach stderr"
ok "revdiff: a closed review pane -> no-verdict, cause named rather than numbered"

# nowhere to open a pane -> no-verdict, producesVerdict false. revdiff is a TUI,
# so a session that cannot put a terminal on screen has no review to show, and
# saying so beats launching into a host error.
o=$( cd "$repo" && ANCHOR_HOST_RUNNER='' ITERM_SESSION_ID='' bash "$dispatch" --previous ); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]                        || fail "no-host verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = no-host ]               || fail "no-host raw.exitCode"
[ "$(jq -r .capabilities.producesVerdict <<<"$j")" = false ] || fail "no-host producesVerdict"
ok "revdiff: nowhere to open a pane -> no-verdict, producesVerdict false"

# revdiff not installed -> no-verdict naming the absent tool, not a pane opened
# on nothing.
o=$( cd "$repo" && PATH="/usr/bin:/bin" bash "$dispatch" --previous ); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]           || fail "absent-revdiff verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = absent ]   || fail "absent-revdiff raw.exitCode"
ok "revdiff: not installed -> no-verdict, producesVerdict false"

# ref translation: --previous (HEAD~1...HEAD) -> revdiff base HEAD~1 against HEAD
export REVDIFF_ARGS_FILE="$work/args.txt"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""; o=$(run --previous)
grep -qx 'HEAD~1' "$REVDIFF_ARGS_FILE" || fail "revdiff args missing base HEAD~1: $(cat "$REVDIFF_ARGS_FILE")"
grep -qx 'HEAD'   "$REVDIFF_ARGS_FILE" || fail "revdiff args missing against HEAD"
unset REVDIFF_ARGS_FILE
ok "revdiff: --previous translated to base/against refs"

# --message-file seeds the drafted commit message into the review header, so the
# message is reviewed beside the diff it describes rather than in a chat gate
printf 'wip line\n' >> "$repo/a.txt"
msg="$work/msg.txt"; printf 'Add a feature\n\nThe body explains why.\n' > "$msg"
export REVDIFF_DESC_CAPTURE="$work/desc.md"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(run --local --message-file "$msg")
[ "$(verdict_of "$o")" = approved ] || fail "message-file review verdict"
[ "$(head -1 "$REVDIFF_DESC_CAPTURE")" = "# Add a feature" ] \
  || fail "subject not seeded as the header title: $(head -1 "$REVDIFF_DESC_CAPTURE")"
grep -qx -- '- \*\*body:\*\* The body explains why.' "$REVDIFF_DESC_CAPTURE" \
  || fail "body not seeded as a body row: $(cat "$REVDIFF_DESC_CAPTURE")"
unset REVDIFF_DESC_CAPTURE
ok "--message-file seeds subject as the title and body as a body row"

# ======================= mode and tool selection ======================
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(run --previous); j=$(json_of "$o")
[ "$(jq -r .mode <<<"$j")" = diff ]       || fail "a git range should resolve to diff mode"
[ "$(jq -r .tool <<<"$j")" = revdiff ] || fail "diff mode's default tool should be revdiff"
ok "mode: a git range takes diff mode, and revdiff runs it"

if run --mode bogus --previous 2>/dev/null; then fail "unknown mode should exit non-zero"; fi
ok "mode: an unknown mode exits non-zero"

# ================== tool resolution against installed tools ============
# The resolver only considers tools that are there, so these run under a PATH
# built for the case: a system PATH carries no viewer, and $bin carries revdiff.
system_path="/usr/bin:/bin"

pb() { ( cd "$repo" && PATH="$1" bash "$dispatch" --probe ); }

o=$(pb "$bin:$PATH")
grep -qx 'REVIEW_TOOL=revdiff' <<<"$o" || fail "named and installed -> want revdiff, got: $o"
ok "tool: the viewer the key names is the one the probe reports"

# A named viewer that isn't installed stays named. Substituting one the user
# didn't ask for would report its verdict as theirs, so the probe says the named
# tool cannot open rather than quietly naming another.
git -C "$repo" config anchor.diff.tool definitely-not-installed
o=$(pb "$bin:$PATH")
grep -qx 'REVIEW_TOOL=definitely-not-installed' <<<"$o" \
  || fail "an absent named tool should stay named, got: $o"
grep -qx 'REVIEW_AVAILABLE=0' <<<"$o" \
  || fail "an absent named tool cannot open, got: $o"
! grep -q 'REVIEW_TOOL_CONFIGURED=' <<<"$o" \
  || fail "nothing was substituted, so nothing should report as replaced: $o"
git -C "$repo" config anchor.diff.tool revdiff
ok "tool: an absent named viewer is reported by name, not swapped out"

# No key at all is its own answer: the review names the keys that would pick a
# viewer rather than reaching for anchor's recommendation on the user's behalf.
git -C "$repo" config --unset anchor.diff.tool
o=$(pb "$bin:$PATH")
grep -qx 'REVIEW_TOOL=' <<<"$o"             || fail "no key -> want an empty tool, got: $o"
grep -qx 'REVIEW_TOOL_SOURCE=unset' <<<"$o" || fail "no key -> want source=unset, got: $o"
grep -qx 'REVIEW_AVAILABLE=0' <<<"$o"       || fail "no key -> want AVAILABLE=0, got: $o"
r=$( cd "$repo" && PATH="$bin:$PATH" bash "$dispatch" --previous 2>&1 )
grep -q 'REVIEW_VERDICT=no-verdict' <<<"$r" || fail "no key -> want no-verdict, got: $r"
grep -q 'anchor.diff.tool' <<<"$r"          || fail "no key -> the report should name the key, got: $r"
git -C "$repo" config anchor.diff.tool revdiff
ok "tool: with no viewer named, the review names the key instead of choosing one"

# Named, and installed nowhere: the probe reports the name and that it cannot open.
o=$(pb "$system_path")
grep -qx 'REVIEW_TOOL=revdiff' <<<"$o" || fail "no viewer -> want the configured name, got: $o"
grep -qx 'REVIEW_AVAILABLE=0' <<<"$o"     || fail "no viewer -> want AVAILABLE=0, got: $o"
ok "tool: with nothing installed the probe reports the preference, unavailable"

# The run keeps the configured adapter, whose report names the tool that is
# missing. Nothing below it stands in — a viewer the user did not name would
# report its verdict as theirs — so the flow hands off to the skill's fallback
# ladder instead.
o=$( cd "$repo" && PATH="$system_path" bash "$dispatch" --previous )
[ "$(jq -r .tool <<<"$(json_of "$o")")" = revdiff ] \
  || fail "no viewer -> want the configured adapter, got: $(json_of "$o")"
ok "tool: no viewer installed keeps the configured adapter, never a difftool"

# `git` names no tool. A difftool git can launch is selectable (DIFF-18) and
# answers through `anchor_difftool_known`, but the bare binary is not one of
# those names, so asking for it fails the way any other typo does.
git -C "$repo" config anchor.diff.tool git
o=$( cd "$repo" && PATH="$system_path" bash "$dispatch" --previous 2>&1 )
grep -q 'REVIEW_VERDICT=no-verdict' <<<"$o" \
  || fail "git tool -> want no-verdict, got: $o"
grep -q "no adapter for diff tool 'git'" <<<"$o" \
  || fail "git tool -> want the no-adapter error naming it, got: $o"
! grep -q 'REVIEW_VERDICT=approved' <<<"$o" || fail "git tool -> nothing should be approved, got: $o"
git -C "$repo" config anchor.diff.tool revdiff
ok "tool: git names no tool, so asking for it fails like any typo"

# edit mode is selectable but never substituted in, so an absent viewer doesn't
# turn a changeset review into an editor buffer.
o=$( cd "$repo" && PATH="$system_path" bash "$dispatch" --probe --mode edit )
grep -qx 'REVIEW_MODE=edit' <<<"$o" || fail "--mode edit -> want edit, got: $o"
ok "mode: a mode asked for with --mode stays selected and is never substituted away"

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

export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
export REVDIFF_DESC_CAPTURE="$work/desc.md"
o=$( cd "$other" && bash "$dispatch" --previous --repo "$repo" )
[ "$(verdict_of "$o")" = approved ] || fail "trailing --repo -> $(verdict_of "$o"), want approved"
grep -qx -- '- \*\*repo:\*\* repo' "$REVDIFF_DESC_CAPTURE" \
  || fail "trailing --repo reviewed the wrong checkout: $(cat "$REVDIFF_DESC_CAPTURE")"
unset REVDIFF_DESC_CAPTURE
ok "context: --repo after the mode retargets the review (TARGET-09)"

# a value that looks like a context flag stays a value
o=$( cd "$other" && bash "$dispatch" --previous --repo "$repo" --title '--repo' )
[ "$(verdict_of "$o")" = approved ] || fail "--title '--repo' should stay a title value: $o"
ok "context: a flag-shaped option value is not read as a context flag"

# per-skill tool selection still resolves when --skill trails the mode
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$( cd "$other" && bash "$dispatch" --previous --repo "$repo" --skill trailing )
[ "$(jq -r .tool <<<"$(json_of "$o")")" = revdiff ] \
  || fail "trailing --skill did not select the per-skill tool: $(json_of "$o")"
ok "context: --skill after the mode still selects the per-skill tool"

# a misspelled flag is an error, not a silently dropped argument
rc=0; o=$( cd "$repo" && bash "$dispatch" --previous --repoo "$repo" 2>&1 ) || rc=$?
[ "$rc" -eq 64 ] || fail "unknown option -> want exit 64, got $rc: $o"
! grep -q 'REVIEW_VERDICT=' <<<"$o" || fail "unknown option should review nothing: $o"
ok "context: an unknown option exits 64 instead of being dropped"

rc=0; o=$( cd "$repo" && bash "$dispatch" --previous HEAD~1...HEAD 2>&1 ) || rc=$?
[ "$rc" -eq 64 ] || fail "extra positional -> want exit 64, got $rc: $o"
ok "context: an extra positional argument exits 64"

# ================== --local staging is path-scoped ========================
# A new file has to reach the index to show up in `git diff HEAD`, which is why
# --local stages at all. It stages only what it was given: the reviewer of a
# shared checkout should not be handed another session's in-flight file.
git -C "$repo" reset --quiet
printf 'new and mine\n' > "$repo/mine.txt"
printf 'not mine\n' > "$repo/other-session.txt"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(run --local --path mine.txt)
[ "$(verdict_of "$o")" = approved ] || fail "--local --path verdict: $o"
git -C "$repo" diff --cached --name-only | grep -qx 'mine.txt' || fail "--path mine.txt should be staged"
if git -C "$repo" diff --cached --name-only | grep -qx 'other-session.txt'; then
  fail "--local must not stage a path it was not given"
fi
ok "--local: stages only --path, never the whole tree"

# a --path with nothing to stage stops the review rather than showing a
# changeset that is missing a file the caller thinks is in it
rc=0; out=$( run --local --path nope.txt 2>&1 ) || rc=$?
[ "$rc" -eq 65 ] || fail "--local with an unchanged --path -> want 65, got $rc: $out"
! grep -q 'REVIEW_VERDICT=' <<<"$out" || fail "nothing should be reviewed: $out"
ok "--local: a --path with nothing to stage exits 65 without reviewing"
git -C "$repo" reset --quiet
rm -f "$repo/other-session.txt"

# ================== empty range ==========================================
# Nothing to show means nothing was reviewed, and a viewer quit on an empty diff
# is indistinguishable from an approval — so the dispatcher never launches one.
export REVDIFF_ARGS_FILE="$work/empty-args.txt"; rm -f "$REVDIFF_ARGS_FILE"
o=$( cd "$other" && bash "$dispatch" --local 2>/dev/null ); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "empty range -> $(verdict_of "$o"), want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = empty-range ] || fail "empty range raw.exitCode: $j"
[ "$(jq -r .capabilities.producesVerdict <<<"$j")" = false ] || fail "empty range producesVerdict"
[ ! -e "$REVDIFF_ARGS_FILE" ] || fail "empty range should not launch a viewer"
unset REVDIFF_ARGS_FILE
ok "empty range: no-verdict, nothing launched (DIFF-21)"

echo "# all checks passed"
