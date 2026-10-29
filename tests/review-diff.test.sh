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
# A changes-requested --local review saves its state under $TMPDIR (DIFF-37).
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"

bin="$work/bin"
mkdir -p "$bin"

# --- stub split runner: the adapter builds revdiff's command string and hands
# it to scripts/lib/review-host.sh, which opens it in a pane. This stub stands in
# via ANCHOR_HOST_RUNNER, so the suite drives the real command string rather
# than a launcher's argv: it unpacks the string back into an argv, records it to
# $REVDIFF_ARGS_FILE and the variables it sets to $REVDIFF_ENV_FILE, copies the seeded header (--description-file, which the
# adapter deletes on return) to $REVDIFF_DESC_CAPTURE, writes
# $REVDIFF_STUB_OUTPUT to the --output file the adapter named, and exits
# $REVDIFF_STUB_RC. It also adds a note on the line of (context).md's Verdict
# section that REVDIFF_STUB_CHOOSE names (accept, reject, both, or empty for
# none; accept when unset), as a reviewer choosing does, exiting 10 for it.
# With $REVDIFF_STUB_EDIT, it writes that text over each file it shows but the
# context file, as `e` in revdiff does.
cat > "$bin/stub-host-runner.sh" <<'EOF'
#!/usr/bin/env bash
cmd=${1% 2>*}
eval "set -- $cmd"
env=()
while [[ "$1" == REVDIFF_*=* ]]; do env+=("$1"); shift; done
[ -n "${REVDIFF_ENV_FILE:-}" ] && printf '%s\n' "${env[@]}" > "$REVDIFF_ENV_FILE"
shift   # the revdiff binary itself
[ -n "${REVDIFF_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$REVDIFF_ARGS_FILE"
out=""
for a in "$@"; do
  case "$a" in
    --output=*) out="${a#*=}" ;;
    --keys=*) [ -n "${REVDIFF_KEYS_CAPTURE:-}" ] && cp "${a#*=}" "$REVDIFF_KEYS_CAPTURE" ;;
    --only=*) [ -n "${REVDIFF_STUB_EDIT:-}" ] && [ "${a#*=}" != "(context).md" ] \
                && printf '%s\n' "$REVDIFF_STUB_EDIT" > "${a#*=}" ;;
    --description-file=*)
      desc="${a#*=}"
      [ -n "${REVDIFF_DESC_CAPTURE:-}" ] && cp "$desc" "$REVDIFF_DESC_CAPTURE" ;;
  esac
done
body="${REVDIFF_STUB_OUTPUT:-}" rc="${REVDIFF_STUB_RC:-0}"
for c in ${REVDIFF_STUB_CHOOSE-accept}; do
  label=$(printf '%s' "${c:0:1}" | tr '[:lower:]' '[:upper:]')${c:1}
  n=$(grep -n -F -- "- **$label" "(context).md" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$n" ] || continue
  body="${body:+$body$'\n\n'}## (context).md:$n (+)"$'\n'"$c"
  [ "$rc" != 0 ] || rc=10
done
[ -n "$out" ] && printf '%s' "$body" > "$out"
# The tree as the reviewer saw it: the context file, and what git reports.
if [ -n "${REVDIFF_TREE_CAPTURE:-}" ]; then
  cp "(context).md" "$REVDIFF_TREE_CAPTURE.context" 2>/dev/null || rm -f "$REVDIFF_TREE_CAPTURE.context"
  git status --porcelain > "$REVDIFF_TREE_CAPTURE.status"
  pwd > "$REVDIFF_TREE_CAPTURE.pwd"
fi
exit "$rc"
EOF
chmod +x "$bin/stub-host-runner.sh"
export ANCHOR_HOST_RUNNER="$bin/stub-host-runner.sh"

# --- stub revdiff: never executed (the stub runner intercepts the command), but
# the adapter resolves the tool on PATH before building it, so the suite has to
# carry one to test against a machine that has revdiff rather than whatever the
# host happens to have installed.
# Its one direct call is --dump-keys, answered with a remapped next-change key.
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --dump-keys ] && [ -z "${REVDIFF_STUB_NO_KEYS:-}" ] \
  && printf '%s\n' '# File/Hunk' 'map n next_item' 'map > next_hunk' 'map [ prev_hunk' \
       '# Annotations' 'map a confirm' 'map enter confirm' 'map A annotate_file' \
       '# Quit' 'map q quit' 'map Q discard_quit'
exit 0
EOF
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

# rc 0, no annotations -> no verdict chosen, no comments, completeness null
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""; o=$(REVDIFF_STUB_CHOOSE="" run --previous 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]               || fail "revdiff rc0 verdict: $o"
[ "$(jq -r .raw.exitCode <<<"$j")" = undecided ]    || fail "revdiff rc0 is named undecided: $(jq -c .raw <<<"$j")"
grep -q 'no verdict chosen' "$work/err.txt"         || fail "an undecided review says so on stderr"
[ "$(jq -r .tool <<<"$j")" = revdiff ]           || fail "revdiff tool"
[ "$(jq '.comments|length' <<<"$j")" = 0 ]          || fail "revdiff rc0 no comments"
[ "$(jq -r .reviewCompleteness <<<"$j")" = null ]   || fail "revdiff completeness=null"
[ "$(jq -r 'has("severitySource")' <<<"$j")" = false ] || fail "revdiff still emits severitySource"
[ "$(jq -r .capabilities.sideMarkers <<<"$j")" = true ] || fail "revdiff caps.sideMarkers"
ok "revdiff: rc 0 -> undecided, no comments, completeness null"

# rc 10 with a line annotation and a file-level annotation
md=$'## a.txt:2 (+)\nuse a constant here\n\n## a.txt (file-level)\nsplit this file'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(REVDIFF_STUB_CHOOSE="" run --previous); j=$(json_of "$o")
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

# The verdict is a note on a line of (context).md's Verdict section.
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(REVDIFF_STUB_CHOOSE=accept REVDIFF_KEYS_CAPTURE="$work/keys.txt" run --skill commit --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "a note on Accept approves: $o"
[ "$(jq -r '.comments[0] | "\(.target) \(.choice)"' <<<"$j")" = "verdict accept" ] || fail "the choice is a verdict comment: $j"
grep -qxF 'unmap Q' "$work/keys.txt" || fail "Q should be unbound for the review: $(cat "$work/keys.txt")"
! grep -q 'discard_quit' "$work/keys.txt" || fail "revdiff applies unmaps first, so the binding itself is left out: $(cat "$work/keys.txt")"
grep -qxF 'map a confirm' "$work/keys.txt" || fail "the review keeps the bindings revdiff has: $(cat "$work/keys.txt")"
o=$(REVDIFF_STUB_CHOOSE=reject run --skill commit --previous)
[ "$(verdict_of "$o")" = rejected ] || fail "a note on Reject rejects: $o"
o=$(REVDIFF_STUB_CHOOSE="accept reject" run --skill commit --previous 2>/dev/null); j=$(json_of "$o")
if [ "$(verdict_of "$o")" != no-verdict ] || [ "$(jq -r .raw.exitCode <<<"$j")" != undecided ]; then fail "both choices are undecided: $o"; fi
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nrename this later'
o=$(REVDIFF_STUB_CHOOSE=accept run --skill commit --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "Accept with a note approves: $o"
[ "$(jq '[.comments[] | select(.target == "line")] | length' <<<"$j")" = 1 ] || fail "Accept keeps the other notes: $j"
o=$(REVDIFF_STUB_CHOOSE=reject run --skill commit --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = rejected ] || fail "Reject with a note rejects: $o"
REVDIFF_STUB_OUTPUT=""
ok "revdiff: a note on Accept or Reject is the verdict, both or neither is undecided, and Q is unbound"

# One note that says only a verdict word chooses, wherever it sits; among other
# notes it is one more note.
export REVDIFF_STUB_CHOOSE="" REVDIFF_STUB_RC=10
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nLGTM.'
o=$(run --skill commit --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "a lone lgtm approves: $o"
[ "$(jq -r '.comments[0] | "\(.target) \(.choice)"' <<<"$j")" = "verdict accept" ] || fail "the lone word is the choice: $j"
REVDIFF_STUB_OUTPUT=$'## a.txt (file-level)\nship it'
o=$(run --skill commit --previous)
[ "$(verdict_of "$o")" = approved ] || fail "a lone file-level ship it approves: $o"
REVDIFF_STUB_OUTPUT=$'## (context).md:1 (+)\nstop'
o=$(run --skill commit --previous)
[ "$(verdict_of "$o")" = rejected ] || fail "a lone stop on the context file rejects: $o"
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\ncancel'
o=$(run --skill commit --previous)
[ "$(verdict_of "$o")" = rejected ] || fail "a lone cancel rejects: $o"
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nlgtm\n\n## a.txt:1 (+)\nrename this'
o=$(run --skill commit --previous); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ] || fail "lgtm among other notes is not approval: $o"
[ "$(jq '[.comments[] | select(.target == "verdict")] | length' <<<"$j")" = 0 ] || fail "lgtm among other notes stays a note: $j"
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nlgtm, but rename it'
o=$(run --skill commit --previous)
[ "$(verdict_of "$o")" = changes-requested ] || fail "a note that says more than the word is a note: $o"
printf '## a.txt:2 (+)\n#1 seeded\n' > "$work/one-note.md"
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nreject'
o=$(run --previous --annotations "$work/one-note.md"); returned=$(sed -n 's/^REVIEW_RETURNED=//p' <<<"$o")
[ "$(verdict_of "$o")" = changes-requested ] || fail "reject on a preloaded note answers that note: $o"
[ "$(jq -r '.[0].body' "$returned")" = reject ] || fail "the answer reaches the caller: $(cat "$returned")"
# In a review of items, only the shared table decides, off its rows, and answers
# on the items' notes don't count against the word.
# shellcheck source=../scripts/lib/verdict.sh
source "$here/../scripts/lib/verdict.sh"
{ printf '# Batch\n'; anchor_verdict_section "publish" "stop"; printf '| # | slug |\n|---|---|\n| 1 | one |\n'; } > "$work/batch-table.md"
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\n#1 seeded\n\n## a.txt:1 (+)\nabort'
o=$(run --previous --annotations "$work/one-note.md")
[ "$(verdict_of "$o")" = changes-requested ] || fail "in a review of items, a lone abort on an item's file is a note: $o"
cp "$work/batch-table.md" "$repo/(context).md"
row=$(grep -n '^| 1 |' "$work/batch-table.md" | cut -d: -f1)
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\n#1 seeded\n\n## (context).md:1 (+)\nabort'
o=$(run --previous --annotations "$work/one-note.md"); returned=$(sed -n 's/^REVIEW_RETURNED=//p' <<<"$o")
[ "$(verdict_of "$o")" = rejected ] || fail "a lone abort on the shared table rejects: $o"
[ "$(jq -c 'map(.body)' "$returned")" = '["#1 seeded"]' ] || fail "the choosing note stays out of the returned notes: $(cat "$returned")"
REVDIFF_STUB_OUTPUT="## (context).md:$row (+)"$'\nlgtm'
o=$(run --previous --annotations "$work/one-note.md")
[ "$(verdict_of "$o")" = changes-requested ] || fail "lgtm on an item's row answers that row: $o"
REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\ndrop\n\n## (context).md:1 (+)\nlgtm'
o=$(run --previous --annotations "$work/one-note.md")
[ "$(verdict_of "$o")" = approved ] || fail "an item answered drop doesn't stop a lone lgtm on the table: $o"
rm -f "$repo/(context).md"
unset REVDIFF_STUB_CHOOSE; REVDIFF_STUB_OUTPUT=""
ok "revdiff: a lone lgtm or stop anywhere chooses, but not among other notes or on a preloaded one, and in a review of items only on the shared table"

# removed-side marker (-)
md=$'## a.txt:2 (-)\nthis deletion looks wrong'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(run --previous); j=$(json_of "$o")
[ "$(jq -r '.comments[0].side' <<<"$j")" = old ] || fail "revdiff (-) -> side=old"
ok "revdiff: (-) marker -> side=old"

# the header sits at the tree root as (context).md, which git never sees, and
# --only carries it beside every changed path; the file is gone once it closes
cap="$work/tree"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT="" REVDIFF_TREE_CAPTURE="$cap" REVDIFF_ARGS_FILE="$work/ctx.args"
o=$(run --previous)
[ -s "$cap.context" ]                                  || fail "the review should open with (context).md at the root"
head -1 "$cap.context" | grep -q '^# '                 || fail "(context).md should open with the title as a heading: $(cat "$cap.context")"
[ "$(sed -n 2p "$cap.context")" = "" ] || fail "a blank line sets the title off: $(cat "$cap.context")"
[ "$(grep -cx '' "$cap.context")" = 1 ] || fail "a title with no body spends no other blank line: $(cat "$cap.context")"
# shellcheck disable=SC2016
[ "$(sed -n 3p "$cap.context")" = 'in `HEAD~1...HEAD`' ] \
  || fail "the size comes straight after the title: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qE -- '^│ `\[` ← prev +next → `>` │$' "$cap.context" \
  || fail "(context).md should name prev and next on one row: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qF -- '│ `a` to the current line' "$cap.context" || fail "(context).md should name one key to annotate a line: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qF -- '│ `A` to the current file' "$cap.context" || fail "(context).md should name one key to annotate a file: $(cat "$cap.context")"
# shellcheck disable=SC2016
[ "$(grep '^│' "$cap.context" | tail -1 | sed 's/ *│$//')" = '│ *Tell the agent "hide hints" to stop showing these.*' ] \
  || fail "(context).md should say how to hide the keys: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qxF -- '`repo` on `main`' "$cap.context"         || fail "(context).md should say where the change sits: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qxF -- 'commit `'"$(git -C "$repo" rev-parse --short HEAD)"'` by T' "$cap.context" \
  || fail "(context).md should name the commit and its author: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qxF -- 'in `HEAD~1...HEAD`' "$cap.context" \
  || fail "(context).md should give the range: $(cat "$cap.context")"
# shellcheck disable=SC2016
[ "$(sed -n '/^```diff$/,/^```$/p' "$cap.context")" = "$(printf '%s\n' '```diff' ' 1 file' '+██████████ 1' '```')" ] \
  || fail "(context).md should draw the change's size as bars in a diff fence: $(cat "$cap.context")"
[ ! -s "$cap.status" ]                                 || fail "git should see nothing while the review is open: $(cat "$cap.status")"
grep -qxF -- '--only=(context).md' "$work/ctx.args"    || fail "--only should name the context file: $(cat "$work/ctx.args")"
grep -qxF -- '--only=a.txt' "$work/ctx.args"           || fail "--only should still name the changed file: $(cat "$work/ctx.args")"
[ ! -e "$repo/(context).md" ]                          || fail "(context).md should be removed when the review closes"
grep -qxF '/(context).md' "$(git -C "$repo" rev-parse --git-path info/exclude)" \
  || grep -qxF '/(context).md' "$repo/$(git -C "$repo" rev-parse --git-path info/exclude)" \
  || fail "info/exclude should carry the context file"
ok "revdiff: the header is a (context).md at the root that git never sees, gone when the review closes"

# a review that preloads notes carries its own table there and gets no context
printf '## a.txt:2 (+)\nseeded\n' > "$work/preload.md"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nseeded'
o=$(run --previous --annotations "$work/preload.md")
[ ! -e "$cap.context" ]                                || fail "a review with preloaded notes should get no context file"
! grep -qF -- '--only=(context).md' "$work/ctx.args"   || fail "a review with preloaded notes should not name the context file"
ok "revdiff: a review that preloads notes gets no context file"

# its own table in that place is shown though git excludes it, and a note on it
# reads back as a note on the table
printf '# Round 1\n\n| # | slug |\n|---|---|\n| 1 | one |\n' > "$repo/(context).md"
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## (context).md:5 (+)\ndrop this one'
o=$(run --previous --annotations "$work/preload.md"); j=$(json_of "$o")
rm -f "$repo/(context).md"
grep -qxF -- '--only=(context).md' "$work/ctx.args"    || fail "a preloaded review's own table should be named: $(cat "$work/ctx.args")"
grep -qxF -- '--only=a.txt' "$work/ctx.args"           || fail "the changed file should still be named: $(cat "$work/ctx.args")"
[ "$(jq -r '.comments[0] | "\(.target) \(.file) \(.startLine)"' <<<"$j")" = "line (context).md 5" ] \
  || fail "a note on the table should stay on the table: $(jq -c '.comments' <<<"$j")"
ok "revdiff: a preloaded review's own (context).md is shown, and notes on it stay on it"

# The caller's table carries a Verdict section too: a preloaded note returned as
# it was is no answer, and the choice stays out of the notes the caller reads.
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nseeded'
cp "$work/batch-table.md" "$repo/(context).md"
o=$(REVDIFF_STUB_CHOOSE="" run --previous --annotations "$work/preload.md" 2>/dev/null); j=$(json_of "$o")
[ "$(jq -r .raw.exitCode <<<"$j")" = undecided ] || fail "a batch returned as seeded, nothing chosen, is undecided: $o"
cp "$work/batch-table.md" "$repo/(context).md"
o=$(run --previous --annotations "$work/preload.md"); returned=$(sed -n 's/^REVIEW_RETURNED=//p' <<<"$o")
[ "$(verdict_of "$o")" = approved ] || fail "Accept on a batch's table approves: $o"
[ "$(jq -c 'map(.target)' "$returned")" = '["line"]' ] || fail "the choice stays out of the returned notes: $(cat "$returned")"
cp "$work/batch-table.md" "$repo/(context).md"
o=$(REVDIFF_STUB_CHOOSE=reject run --previous --annotations "$work/preload.md")
[ "$(verdict_of "$o")" = rejected ] || fail "Reject on a batch's table rejects: $o"
rm -f "$repo/(context).md"
ok "revdiff: a caller's table chooses the same way, and the choice isn't one of its notes"
unset REVDIFF_TREE_CAPTURE REVDIFF_ARGS_FILE

# unchanged-line marker ( ) -> a line comment on the new side, not a changeset one
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## a.txt:1 ( )\nnote on context\n\n## a.txt:1-2 ( )\nnote on a range'
o=$(run --previous); j=$(json_of "$o")
[ "$(jq -r '.comments[0] | "\(.target) \(.file) \(.startLine) \(.side)"' <<<"$j")" = "line a.txt 1 new" ] \
  || fail "( ) -> line a.txt 1 new, got $(jq -c '.comments[0]' <<<"$j")"
[ "$(jq -r '.comments[1] | "\(.startLine)-\(.endLine) \(.side)"' <<<"$j")" = "1-2 new" ] \
  || fail "( ) range -> 1-2 new, got $(jq -c '.comments[1]' <<<"$j")"
ok "revdiff: ( ) marker -> a line comment on the new side"

# --annotations preloads notes and returns the set the reviewer left as JSON
notes="$work/notes.md"; printf '## a.txt:2 (+)\n#1 seeded\n' > "$notes"
export REVDIFF_ARGS_FILE="$work/args.txt"
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\n#1 seeded, edited'
o=$(run --previous --annotations "$notes")
grep -qx -- "--annotations=$notes" "$REVDIFF_ARGS_FILE" || fail "--annotations not passed: $(cat "$REVDIFF_ARGS_FILE")"
returned=$(sed -n 's/^REVIEW_RETURNED=//p' <<<"$o")
[ "$returned" = "$work/notes.returned.json" ] || fail "REVIEW_RETURNED path: $o"
[ "$(jq -r '.[0].body' "$returned")" = "#1 seeded, edited" ] || fail "returned notes: $(cat "$returned")"
unset REVDIFF_ARGS_FILE
ok "--annotations: passed to revdiff, and the returned set lands in REVIEW_RETURNED"

# --untracked reaches revdiff on a working-tree review, and is refused on two refs
export REVDIFF_ARGS_FILE="$work/args.txt" REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
run HEAD --untracked >/dev/null
grep -qx -- '--untracked' "$REVDIFF_ARGS_FILE" || fail "--untracked not passed: $(cat "$REVDIFF_ARGS_FILE")"
git -C "$repo" checkout --quiet -- a.txt
rc=0; run --previous --untracked >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "--untracked over two commits should exit 64, got $rc"
unset REVDIFF_ARGS_FILE
ok "--untracked: passed on a working-tree review, refused between two commits"

# a viewer that can't preload notes refuses rather than dropping them
git -C "$repo" config difftool.stubtool.cmd true
git -C "$repo" config anchor.diff.tool stubtool
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
o=$(run HEAD --annotations "$notes" 2>/dev/null); j=$(json_of "$o")
[ "$(jq -r .raw.exitCode <<<"$j")" = annotations-unsupported ] || fail "difftool + annotations: $j"
git -C "$repo" checkout --quiet -- a.txt
git -C "$repo" config anchor.diff.tool revdiff
ok "--annotations: a viewer that can't preload notes refuses the review"

# --explain: the agent's notes on its own change ride with the message header,
# and a note the reviewer only read, or deleted, is no feedback (UX-12, DIFF-41)
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
printf '{"notes":[{"file":"a.txt","line":3,"note":"three closes the list"}]}\n' > "$work/explain-in.json"
e=$( cd "$repo" && bash "$here/../scripts/review-explain.sh" --notes "$work/explain-in.json" --path a.txt )
xnotes=$(sed -n 's/^EXPLAIN_NOTES=//p' <<<"$e")
xmsg="$work/xmsg.txt"; printf 'Add three\n' > "$xmsg"
[ "$(sed -n 's/^REVIEW_PRELOADS=//p' <<<"$(run --skill commit --probe --local)")" = 1 ] || fail "revdiff preloads notes"
export REVDIFF_ARGS_FILE="$work/x.args" REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT; REVDIFF_STUB_OUTPUT=$(cat "$xnotes")
o=$(REVDIFF_TREE_CAPTURE="$work/x" run --skill commit --local --message-file "$xmsg" --path a.txt --explain "$xnotes")
grep -qx -- "--annotations=$xnotes" "$REVDIFF_ARGS_FILE" || fail "--explain notes not preloaded: $(cat "$REVDIFF_ARGS_FILE")"
grep -qx '# Add three' "$work/x.context" || fail "the message header rides with the notes: $(cat "$work/x.context" 2>&1)"
[ "$(verdict_of "$o")" = approved ] || fail "a note returned as seeded was read, not feedback: $o"
REVDIFF_STUB_OUTPUT=""
o=$(run --skill commit --local --message-file "$xmsg" --path a.txt --explain "$xnotes")
[ "$(verdict_of "$o")" = approved ] || fail "a deleted note was read and set aside: $o"
REVDIFF_STUB_OUTPUT=$(sed 's/three closes the list/why not four?/' "$xnotes")
o=$(REVDIFF_STUB_CHOOSE="" run --skill commit --local --message-file "$xmsg" --path a.txt --explain "$xnotes"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ] || fail "an edited note is feedback: $o"
[ "$(jq -r '.comments[0].body' <<<"$j")" = 'why not four?' ] || fail "the edited note comes back: $j"
unset REVDIFF_ARGS_FILE
ok "--explain: notes ride with the header, and only an edited note is feedback"

# A viewer that can't show notes opens without them, and the probe says so first.
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
git -C "$repo" config anchor.diff.tool stubtool
[ "$(sed -n 's/^REVIEW_PRELOADS=//p' <<<"$(run --skill commit --probe --local)")" = 0 ] || fail "a difftool doesn't preload notes"
o=$(run --skill commit --local --message-file "$xmsg" --path a.txt --explain "$xnotes" 2>/dev/null); j=$(json_of "$o")
[ "$(jq -r .raw.exitCode <<<"$j")" != annotations-unsupported ] || fail "--explain should open without the notes: $j"
[ "$(verdict_of "$o")" = approved ] || fail "a difftool review with --explain still grades: $o"
git -C "$repo" config anchor.diff.tool revdiff
git -C "$repo" reset --quiet
git -C "$repo" checkout --quiet -- a.txt
ok "--explain: a viewer that can't show notes opens without them, and the probe reports it"



# A --files review runs in a scratch repo, so it gets the context file and the
# keys; the file keeps the right side's name.
printf 'old line\n' > "$work/current.md"; printf 'new line\n' > "$work/draft.md"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT="" REVDIFF_TREE_CAPTURE="$cap" REVDIFF_ARGS_FILE="$work/files.args"
o=$(run --skill prepare-review --mode diff --files "$work/current.md" "$work/draft.md" --title 'CR description' --detail branch=feature)
[ "$(verdict_of "$o")" = approved ] || fail "--files: a clean q approves: $o"
[ "$(cat "$cap.pwd")" != "$repo" ] || fail "--files should run outside the user's repo"
[ ! -d "$(cat "$cap.pwd")" ] || fail "--files should remove its scratch repo: $(cat "$cap.pwd")"
! grep -q -- '--compare-' "$work/files.args" || fail "--files should not use compare mode: $(cat "$work/files.args")"
grep -qxF -- '--only=(context).md' "$work/files.args" || fail "--files should show the context file: $(cat "$work/files.args")"
grep -qxF -- '--only=draft.md' "$work/files.args" || fail "--files keeps the right side's name: $(cat "$work/files.args")"
grep -qx '# CR description' "$cap.context" || fail "--files header title: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qxF '`repo` on `feature`' "$cap.context" || fail "--files names the repo it was asked from: $(cat "$cap.context")"
# shellcheck disable=SC2016
grep -qF 'next → `>`' "$cap.context" || fail "--files shows the keys: $(cat "$cap.context")"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "--files touched the user's repo: $(git -C "$repo" status --porcelain)"
REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## draft.md:1 (+)\nsay why'
o=$(run --skill prepare-review --mode diff --files "$work/current.md" "$work/draft.md"); j=$(json_of "$o")
[ "$(jq -r '.comments[0] | "\(.file):\(.startLine) \(.body)"' <<<"$j")" = "draft.md:1 say why" ] || fail "--files note: $j"
: > "$work/none.md"
REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
run --skill issue --mode diff --files "$work/none.md" "$work/draft.md" >/dev/null
grep -qF '+██' "$cap.context" || fail "--files with no prior version draws the size: $(cat "$cap.context")"
ok "revdiff: a --files review gets the context file and the keys, in a scratch repo"

# --name gives the file the reviewed object's reference, and a note on it comes
# back under that name.
REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## acme#7.md:1 (+)\nsay why'
o=$(run --skill issue --mode diff --files "$work/current.md" "$work/draft.md" --name 'acme#7'); j=$(json_of "$o")
grep -qxF -- '--only=acme#7.md' "$work/files.args" || fail "--name should name the file: $(cat "$work/files.args")"
[ "$(jq -r '.comments[0] | "\(.file):\(.startLine) \(.body)"' <<<"$j")" = "acme#7.md:1 say why" ] || fail "--name note: $j"
rc=0; run --mode diff --files "$work/current.md" "$work/draft.md" --name 'group/acme#7' >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "--name holding a / should exit 64, got $rc"
unset REVDIFF_TREE_CAPTURE REVDIFF_ARGS_FILE
ok "revdiff: --name names a --files review's file for the object it edits"

# `e` in revdiff edits the draft's copy in the scratch repo. The edit is written
# over the draft, and accepting it brings it back for approval as edited.
printf 'the draft\n' > "$work/edit-draft.md"
REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(REVDIFF_STUB_EDIT='the draft, edited' run --skill issue --mode diff --files "$work/current.md" "$work/edit-draft.md" 2>/dev/null); j=$(json_of "$o")
[ "$(jq -r .verdict <<<"$j")" = changes-requested ] || fail "an edited draft should come back for approval: $j"
[ "$(jq -r '.editedFields[0] | "\(.target) \(.edited)"' <<<"$j")" = "issue-body the draft, edited" ] || fail "the edit should ride in editedFields: $j"
[ "$(cat "$work/edit-draft.md")" = "the draft, edited" ] || fail "the edit should be written over the draft: $(cat "$work/edit-draft.md")"
o=$(run --skill issue --mode diff --files "$work/current.md" "$work/edit-draft.md"); j=$(json_of "$o")
[ "$(jq -r '"\(.verdict) \(.editedFields | length)"' <<<"$j")" = "approved 0" ] || fail "an unedited accept is approved: $j"
ok "revdiff: a draft edited with e is kept, and comes back for approval as edited"

# A draft review offers to start over in the editor, and choosing it does, with
# the reviewer's other notes in the editor's context.
cat > "$bin/stub-editor.sh" <<'STUB'
#!/usr/bin/env bash
cp "$1" "$EDITOR_BUFFER_CAPTURE"
touch "$1"
STUB
chmod +x "$bin/stub-editor.sh"
REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## acme#7.md:1 (+)\nsay why'
o=$(GIT_EDITOR=hx ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" EDITOR_BUFFER_CAPTURE="$work/relaunch.buffer" \
    REVDIFF_TREE_CAPTURE="$work/relaunch" REVDIFF_STUB_CHOOSE=relaunch \
    run --skill issue --mode diff --files "$work/current.md" "$work/edit-draft.md" --name 'acme#7'); j=$(json_of "$o")
grep -qF -- '- **Relaunch in hx**: quit revdiff and start this review over in hx' "$work/relaunch.context" \
  || fail "the Verdict section should offer the relaunch: $(cat "$work/relaunch.context")"
[ "$(jq -r '"\(.mode) \(.verdict)"' <<<"$j")" = "edit approved" ] || fail "the relaunch should end as the editor review: $j"
grep -qF 'acme#7.md:1: say why' "$work/relaunch.buffer" || fail "the note should ride into the editor: $(cat "$work/relaunch.buffer")"
REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
REVDIFF_TREE_CAPTURE="$work/plain" run --skill commit --previous >/dev/null
! grep -qF 'Relaunch in' "$work/plain.context" || fail "a review with no draft offers no relaunch: $(cat "$work/plain.context")"
ok "revdiff: a draft review relaunches in the editor, carrying the other notes"

# The host is selected after the scratch repo is entered, so a dispatcher run by
# a relative path still finds its hosts. A stub tmux runs the popup's script in
# place, and the stub revdiff exits 0 with nothing chosen: undecided, which a
# review that never opened would report as no-pane instead.
mkdir -p "$work/tmuxbin"
cat > "$work/tmuxbin/tmux" <<'EOF'
#!/usr/bin/env bash
eval "${!#}"
EOF
chmod +x "$work/tmuxbin/tmux"
o=$( cd "$here/.." && PATH="$work/tmuxbin:$PATH" TMUX=stub ANCHOR_HOST_RUNNER='' ITERM_SESSION_ID='' AGTERM_SESSION_ID='' \
     bash scripts/review-diff.sh --skill prepare-review --tool revdiff --mode diff --files "$work/current.md" "$work/draft.md" 2>/dev/null ); j=$(json_of "$o")
[ "$(jq -r .raw.exitCode <<<"$j")" = undecided ] || fail "a --files review run by a relative path should reach its host: $(jq -c '{verdict,raw}' <<<"$j")"
ok "revdiff: a --files review run by a relative path still reaches its host"

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
o=$( cd "$repo" && ANCHOR_HOST_RUNNER='' ITERM_SESSION_ID='' AGTERM_SESSION_ID='' bash "$dispatch" --previous ); j=$(json_of "$o")
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
[ "$(head -1 "$REVDIFF_DESC_CAPTURE")" = "Add a feature" ] \
  || fail "subject not seeded as the header title: $(head -1 "$REVDIFF_DESC_CAPTURE")"
grep -qx -- 'The body explains why.' "$REVDIFF_DESC_CAPTURE" \
  || fail "body not seeded as a paragraph: $(cat "$REVDIFF_DESC_CAPTURE")"
! grep -q -- 'opened by' "$REVDIFF_DESC_CAPTURE" || fail "a review with no --skill named a skill that opened it"
ok "--message-file seeds subject as the title and body as a paragraph"

# (context).md carries the message's paragraphs as written
pmsg="$work/para-msg.txt"; printf 'Add a feature\n\nFirst paragraph.\n\nSecond paragraph.\n' > "$pmsg"
o=$(REVDIFF_TREE_CAPTURE="$work/para" run --local --message-file "$pmsg")
[ "$(tail -4 "$work/para.context")" = "$(printf '%s\n' '' 'First paragraph.' '' 'Second paragraph.')" ] \
  || fail "(context).md should close on the body, after a blank line, with its paragraph breaks: $(cat "$work/para.context")"
[ "$(grep -n '^First paragraph' "$work/para.context" | cut -d: -f1)" -gt "$(grep -n '^base ' "$work/para.context" | cut -d: -f1)" ] \
  || fail "the body follows where the change sits: $(cat "$work/para.context")"
ok "revdiff: (context).md keeps the commit message's paragraphs"

o=$(REVDIFF_TREE_CAPTURE="$work/cta" run --local --skill commit --message-file "$pmsg")
grep -qxF -- '## Verdict' "$work/cta.context" || fail "(context).md should carry the Verdict section: $(cat "$work/cta.context")"
grep -qxF -- '- **Accept**: commit this change and push it' "$work/cta.context" \
  || fail "Accept should say what approving does next: $(cat "$work/cta.context")"
grep -qF -- '- **Reject**: stop' "$work/cta.context" || fail "Reject should say what it does: $(cat "$work/cta.context")"
! grep -q 'q with' "$work/cta.context" || fail "the box no longer carries the quit lines: $(cat "$work/cta.context")"
! grep -q 'anchor:commit\|Claude' "$work/cta.context" || fail "(context).md names neither the skill nor the model: $(cat "$work/cta.context")"
[ "$(grep -n '^╰' "$work/cta.context" | cut -d: -f1)" -lt "$(grep -n '^## Verdict' "$work/cta.context" | cut -d: -f1)" ] \
  || fail "the Verdict section follows the box: $(cat "$work/cta.context")"
# shellcheck disable=SC2016
[ "$(grep -n '^## Verdict' "$work/cta.context" | cut -d: -f1)" -lt "$(grep -n '^`repo`' "$work/cta.context" | cut -d: -f1)" ] \
  || fail "the repo follows the Verdict section: $(cat "$work/cta.context")"
# shellcheck disable=SC2016
grep -qx 'base `[0-9a-f]*`' "$work/cta.context" || fail "a base no remote holds is named, not linked: $(cat "$work/cta.context")"
ok "revdiff: (context).md boxes the keys, then says what each verdict does"

git -C "$repo" config anchor.hints false
o=$(REVDIFF_TREE_CAPTURE="$work/nohints" run --local --skill commit --message-file "$pmsg")
! grep -q '← prev\|To add an annotation\|hide hints' "$work/nohints.context" || fail "anchor.hints=false hides the keys: $(cat "$work/nohints.context")"
grep -qxF '## Verdict' "$work/nohints.context"  || fail "the Verdict section stays when the keys are hidden"
git -C "$repo" config anchor.diff.hints true
o=$(REVDIFF_TREE_CAPTURE="$work/diffhints" run --local --skill commit --message-file "$pmsg")
grep -q '← prev' "$work/diffhints.context" || fail "anchor.diff.hints=true outranks anchor.hints=false: $(cat "$work/diffhints.context")"
git -C "$repo" config --unset anchor.hints
git -C "$repo" config anchor.diff.hints false
o=$(REVDIFF_TREE_CAPTURE="$work/nodiffhints" run --local --skill commit --message-file "$pmsg")
! grep -q '← prev' "$work/nodiffhints.context" || fail "anchor.diff.hints=false hides the keys: $(cat "$work/nodiffhints.context")"
git -C "$repo" config --unset anchor.diff.hints
o=$(REVDIFF_STUB_NO_KEYS=1 REVDIFF_TREE_CAPTURE="$work/nokeys" run --local --message-file "$pmsg")
! grep -q '← prev\|To add an annotation' "$work/nokeys.context" || fail "a revdiff mapping none of the actions gets no key line: $(cat "$work/nokeys.context")"
ok "revdiff: anchor.hints=false hides the key line, anchor.diff.hints outranks it, and an unmapped action is left out"

# a note on (context).md is the reviewer writing on the message: it must never
# read as approved (CONFIRM-08)
emsg="$work/edited-msg.txt"; printf 'Add retry\n\nWhy it retries.\n' > "$emsg"
md=$'## (context).md:3 ( )\ndrop the second clause'
export REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT="$md"; o=$(REVDIFF_STUB_CHOOSE="" REVDIFF_TREE_CAPTURE="$work/emsg" run --local --message-file "$emsg"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = changes-requested ]                 || fail "a note on the context -> changes-requested, got $(verdict_of "$o")"
[ "$(jq -r '.comments[0].target' <<<"$j")" = commit-message ] || fail "a note on the context targets the commit message"
[ "$(jq -r '.comments[0].file' <<<"$j")" = null ]           || fail "a note on the context carries no file"
[ "$(jq -r '.comments[0].startLine' <<<"$j")" = 3 ] || fail "a note on the context keeps its line: $j"
[ "$(jq -r '.comments[0].quote' <<<"$j")" = "$(sed -n 3p "$work/emsg.context")" ] || fail "a note on the context quotes its line: $j"
ok "revdiff: a note on (context).md comes back as feedback on the commit message"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""

# --skill leads the header with the flow that opened the review and what
# approving hands it, ahead of the rows the caller supplied
o=$(run --skill commit --local --message-file "$msg")
[ "$(sed -n 3,4p "$REVDIFF_DESC_CAPTURE")" = "$(printf '%s\n%s' \
    '  opened by: /anchor:commit' '  next:      commit this change and push it')" ] \
  || fail "the header should lead with the opening skill, values aligned: $(cat "$REVDIFF_DESC_CAPTURE")"
o=$(run --skill resolve-feedback --local --message-file "$msg")
grep -qE '^  next: +commit this fix and push it$' "$REVDIFF_DESC_CAPTURE" \
  || fail "a resolve-feedback fix review should say it commits and pushes next: $(cat "$REVDIFF_DESC_CAPTURE")"
git -C "$repo" update-ref refs/remotes/origin/main HEAD~1
o=$(run --skill commit --commit)
git -C "$repo" update-ref -d refs/remotes/origin/main
grep -qE '^  next: +push these commits$' "$REVDIFF_DESC_CAPTURE" \
  || fail "a commit review of unpushed commits should say they are pushed next: $(cat "$REVDIFF_DESC_CAPTURE")"
o=$(run --skill commit --previous)
! grep -q -- 'next:' "$REVDIFF_DESC_CAPTURE" \
  || fail "a range that may already be pushed should not promise a push: $(cat "$REVDIFF_DESC_CAPTURE")"
o=$(run --skill review HEAD~1...HEAD --title 'Their CR' --detail CR=https://example.com/pr/1)
sed -n 3p "$REVDIFF_DESC_CAPTURE" | grep -qE '^  opened by: +/anchor:review$' \
  || fail "the opening skill should lead the header: $(cat "$REVDIFF_DESC_CAPTURE")"
grep -qE '^  CR: +https://example.com/pr/1$' "$REVDIFF_DESC_CAPTURE" \
  || fail "the opening skill should join the caller's own rows, not replace them: $(cat "$REVDIFF_DESC_CAPTURE")"
unset REVDIFF_DESC_CAPTURE
ok "--skill names the flow that opened the review and what approving does next"

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
grep -qE '^  repo: +repo$' "$REVDIFF_DESC_CAPTURE" \
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
export REVDIFF_ARGS_FILE="$work/scoped-args.txt"
o=$(run --local --path mine.txt)
[ "$(verdict_of "$o")" = approved ] || fail "--local --path verdict: $o"
grep -qx -- '--only=mine.txt' "$REVDIFF_ARGS_FILE" || fail "revdiff should show only --path: $(cat "$REVDIFF_ARGS_FILE")"
unset REVDIFF_ARGS_FILE
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

# --staged-path: a partly staged file is reviewed as the index holds it. The
# working tree carries the hunks the commit leaves out, so revdiff is pointed at
# the staged diff, and nothing is staged on the way in.
rm -f "$repo/mine.txt"
printf 'one\ntwo\nstaged\n' > "$repo/a.txt"; git -C "$repo" add a.txt
printf 'one\ntwo\nstaged\nleft out\n' > "$repo/a.txt"
index_before=$(git -C "$repo" diff --cached)
export REVDIFF_ARGS_FILE="$work/staged-args.txt"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(run --local --staged-path a.txt)
[ "$(verdict_of "$o")" = approved ] || fail "--staged-path verdict: $o"
staged_index=$(sed -n 's/^REVIEW_INDEX=//p' <<<"$o")
[ -n "$staged_index" ] || fail "--local should print REVIEW_INDEX: $o"
grep -qx -- '--staged' "$REVDIFF_ARGS_FILE" || fail "revdiff should get --staged: $(cat "$REVDIFF_ARGS_FILE")"
! grep -qx 'HEAD' "$REVDIFF_ARGS_FILE" || fail "revdiff should not diff the tree against HEAD: $(cat "$REVDIFF_ARGS_FILE")"
[ "$(git -C "$repo" diff --cached)" = "$index_before" ] || fail "--staged-path must not stage"
unset REVDIFF_ARGS_FILE
ok "--local --staged-path: revdiff reviews the index, and nothing is staged"

# REVIEW_INDEX names the index the review showed, so staging more of the file
# after it gives a different id (COMMIT-04e).
o=$(run --local --staged-path a.txt)
[ "$(sed -n 's/^REVIEW_INDEX=//p' <<<"$o")" = "$staged_index" ] || fail "REVIEW_INDEX changed with no change to the index: $o"
git -C "$repo" add a.txt
printf 'one\ntwo\nstaged\nleft out\nagain\n' > "$repo/a.txt"
o=$(run --local --staged-path a.txt)
[ "$(sed -n 's/^REVIEW_INDEX=//p' <<<"$o")" != "$staged_index" ] || fail "REVIEW_INDEX should change once more is staged: $o"
ok "--local: REVIEW_INDEX changes when the reviewed path's index entry does"

# a difftool reports through edits to the working tree, and the index side of a
# staged diff reaches it as temp copies, so its verdict here would be lost
git -C "$repo" config difftool.stubtool.cmd true
git -C "$repo" config anchor.diff.tool stubtool
o=$(run --local --staged-path a.txt 2>/dev/null); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "difftool on a staged review -> $(verdict_of "$o"), want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = staged-unsupported ] || fail "difftool staged raw.exitCode: $j"
git -C "$repo" config anchor.diff.tool revdiff
ok "--local --staged-path: a difftool returns no-verdict rather than losing the reviewer's edits"
git -C "$repo" checkout --quiet -- a.txt
git -C "$repo" reset --quiet --hard

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

# A batch of nothing but new items has no tracked change; under --untracked the
# new files are what is shown, so the range is not empty. The context file alone
# doesn't count.
export REVDIFF_ARGS_FILE="$work/untracked-args.txt"; rm -f "$REVDIFF_ARGS_FILE"
printf '# guide\n' > "$other/(context).md"
o=$( cd "$other" && bash "$dispatch" --tool revdiff HEAD --untracked 2>/dev/null ); j=$(json_of "$o")
[ "$(jq -r .raw.exitCode <<<"$j")" = empty-range ] || fail "the context file alone is no content: $j"
printf 'new\n' > "$other/new-item.md"
o=$( cd "$other" && bash "$dispatch" --tool revdiff HEAD --untracked 2>/dev/null ); j=$(json_of "$o")
[ "$(jq -r .raw.exitCode <<<"$j")" != empty-range ] || fail "a new file under --untracked is content: $j"
[ -e "$REVDIFF_ARGS_FILE" ] || fail "a review of new files only should launch the viewer"
rm -f "$other/new-item.md" "$other/(context).md"
unset REVDIFF_ARGS_FILE
ok "empty range: under --untracked, a new file is content and the context file is not"

# A first commit has no HEAD to diff against; the review runs against the empty
# tree, and the agent's notes anchor the same way.
first="$work/first"
git init --quiet -b main "$first"
git -C "$first" config user.email t@example.com; git -C "$first" config user.name T
git -C "$first" config anchor.diff.tool revdiff
printf 'one\ntwo\n' > "$first/a.txt"
printf '{"notes":[{"file":"a.txt","line":2,"note":"two"}]}\n' > "$work/first-in.json"
e=$( cd "$first" && bash "$here/../scripts/review-explain.sh" --notes "$work/first-in.json" --path a.txt ) \
  || fail "notes anchor on a first commit: $e"
printf 'First\n' > "$work/first-msg.txt"
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$( cd "$first" && bash "$dispatch" --skill commit --local --message-file "$work/first-msg.txt" --path a.txt \
       --explain "$(sed -n 's/^EXPLAIN_NOTES=//p' <<<"$e")" ) || fail "a first commit's review fails: $o"
[ "$(verdict_of "$o")" = approved ] || fail "a first commit's review grades: $o"
[ "$(git -C "$first" rev-list --all | wc -l | tr -d ' ')" = 0 ] || fail "the review leaves the branch with no commit"
ok "--local: a first commit is reviewed against the empty tree"

echo "# all checks passed"
