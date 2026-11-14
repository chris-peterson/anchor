#!/usr/bin/env bash
# Functional test for the reply round (DIFF-37): a `changes-requested` --local
# review saves its state, scripts/review-reply.sh seeds the replies, and
# review-diff.sh --reply opens the next review on what changed since, with the
# replies preloaded and a returned-as-seeded reply read as no feedback.
#
# Drives the real dispatcher through the stub host runner review-diff.test.sh
# uses. Requires jq.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dispatch="$here/../scripts/review-diff.sh"
seed="$here/../scripts/review-reply.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-reply-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
# A review's state dir is the dispatcher's own temp dir, so it lands in $work.
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"

bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/stub-host-runner.sh" <<'EOF'
#!/usr/bin/env bash
cmd=${1% 2>*}
eval "set -- $cmd"
env=()
while [[ "$1" == REVDIFF_*=* ]]; do env+=("$1"); shift; done
[ -n "${REVDIFF_ENV_FILE:-}" ] && printf '%s\n' "${env[@]}" > "$REVDIFF_ENV_FILE"
shift
[ -n "${REVDIFF_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$REVDIFF_ARGS_FILE"
out=""
for a in "$@"; do
  case "$a" in --output=*) out="${a#*=}" ;; esac
done
[ -n "$out" ] && printf '%s' "${REVDIFF_STUB_OUTPUT:-}" > "$out"
[ -n "${REVDIFF_CONTEXT_CAPTURE:-}" ] && cp "(context).md" "$REVDIFF_CONTEXT_CAPTURE"
exit "${REVDIFF_STUB_RC:-0}"
EOF
chmod +x "$bin/stub-host-runner.sh"
export ANCHOR_HOST_RUNNER="$bin/stub-host-runner.sh"
# shellcheck disable=SC2016  # the stub's own $1, expanded when it runs
printf '#!/usr/bin/env bash\n[ "${1:-}" != --version ] || echo "version: v1.14.0"\nexit 0\n' > "$bin/revdiff"
chmod +x "$bin/revdiff"
export PATH="$bin:$PATH"

repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email "t@example.com"
git -C "$repo" config user.name "T"
git -C "$repo" config commit.gpgsign false
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m first
printf 'one\nTWO\nthree\nfour\n' > "$repo/a.txt"
printf 'b1\nb2\n' > "$repo/b.txt"
seq 1 20 | sed 's/^/c/' > "$repo/c.txt"
msg="$work/msg"
printf 'Add b\n\nWhy b exists.\n' > "$msg"

run()  { ( cd "$repo" && bash "$dispatch" --skill commit --local --message-file "$msg" --path a.txt --path b.txt --path c.txt "$@" ); }
key()  { sed -n "s/^$1=//p" <<<"$2"; }

# --- the first review asks four things -------------------------------------
export REVDIFF_STUB_RC=10
export REVDIFF_STUB_OUTPUT=$'## a.txt:2 (+)\nwhy uppercase?\n\n## b.txt:1 (+)\nrename b1 to beta\n\n## (context).md:1 ( )\nshorter subject\n\n## c.txt:5 (+)\nwhat is c5 for?'
o=$(run)
[ "$(key REVIEW_VERDICT "$o")" = changes-requested ] || fail "first review verdict: $o"
state=$(key REVIEW_STATE "$o")
[ -d "$state" ] || fail "a changes-requested --local review should print REVIEW_STATE: $o"
[ "$(jq length "$state/comments.json")" = 4 ] || fail "the state should carry the four comments: $(cat "$state/comments.json")"
reviewed=$(cat "$state/reviewed")
[ "$(git -C "$repo" show "$reviewed:b.txt")" = "$(printf 'b1\nb2')" ] || fail "the snapshot should hold b.txt as reviewed"
[ "$(git -C "$repo" diff --cached --name-only)" = "$(printf 'a.txt\nb.txt\nc.txt')" ] \
  || fail "saving the state should stage nothing past the review's own paths: $(git -C "$repo" diff --cached --name-only)"
ok "a changes-requested --local review saves the tree as it closed, and its comments"

# --- the agent answers -----------------------------------------------------
printf 'beta\nb2\n' > "$repo/b.txt"
printf 'one\nTWO\nthree\nfour\nfive\n' > "$repo/a.txt"
printf 'Add b\n\nWhy b exists, in two words.\n' > "$msg"

cat > "$work/partial.json" <<'EOF'
{"replies": [
  {"comment": 1, "status": "answered", "reply": "It names the constant."},
  {"comment": 2, "status": "done", "reply": "Renamed.", "sites": [{"file": "b.txt", "line": 1}]}
]}
EOF
rc=0; out=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/partial.json" --path a.txt --path b.txt --path c.txt ) || rc=$?
[ "$rc" -eq 65 ] || fail "a note with no reply should exit 65, got $rc: $out"
grep -q '^REPLY_ERROR=comment 3 has no reply: shorter subject$' <<<"$out" || fail "the missing reply should be named: $out"
ok "every note needs a reply"

cat > "$work/replies.json" <<'EOF'
{"replies": [
  {"comment": 1, "status": "answered", "reply": "It names the constant."},
  {"comment": 2, "status": "done", "reply": "Renamed.", "sites": [{"file": "b.txt", "line": 1}]},
  {"comment": 3, "status": "different", "reply": "Kept it; the body says the rest."},
  {"comment": 4, "status": "answered", "reply": "It closes the list."}
]}
EOF
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/replies.json" --path a.txt --path b.txt --path c.txt )
[ "$(key NOTE_COUNT "$s")" = 2 ] || fail "two replies have a line: $s"
[ "$(key IN_CONTEXT_ONLY "$s")" = 2 ] || fail "the subject reply and the unchanged file's reply have no line: $s"
grep -qxF '## a.txt:2 ( )' "$state/notes.md" || fail "a reply near a change sits where the note was: $(cat "$state/notes.md")"
grep -qxF 'You asked: why uppercase?' "$state/notes.md" || fail "a reply opens with what was asked: $(cat "$state/notes.md")"
grep -qxF '## b.txt:1 (+)' "$state/notes.md" || fail "a reply about a changed line sits on it: $(cat "$state/notes.md")"
grep -qxF '🤖 #2 · 🏁 as asked' "$state/notes.md" || fail "a reply is headed with what became of the note: $(cat "$state/notes.md")"
grep -qF '| 3 | shorter subject | ⚠️ done differently | end of file |' "$state/reply-head.md" || fail "the reply table: $(cat "$state/reply-head.md")"
grep -qxF 'Kept it; the body says the rest.' "$state/reply.md" || fail "a reply with no line is written out in full: $(cat "$state/reply.md")"
ok "review-reply.sh anchors each reply and writes the table"

! grep -q '^## c.txt' "$state/notes.md" || fail "a reply in a file unchanged since the review is not a note: $(cat "$state/notes.md")"
grep -qF "| 4 | what is c5 for? | answered | end of file, \`c.txt:5\` |" "$state/reply-head.md" || fail "the table points to the end of the file: $(cat "$state/reply-head.md")"
grep -qxF "\`c.txt:5\`, unchanged since your review:" "$state/reply.md" || fail "the quoted reply names its line: $(cat "$state/reply.md")"
grep -qxF '>    5  c5' "$state/reply.md" || fail "the excerpt marks the line asked about: $(cat "$state/reply.md")"
{ grep -qxF '     2  c2' "$state/reply.md" && grep -qxF '     8  c8' "$state/reply.md"; } || fail "the excerpt carries three lines either side: $(cat "$state/reply.md")"
! grep -qxF '     1  c1' "$state/reply.md" || fail "the excerpt stops three lines out: $(cat "$state/reply.md")"
grep -qxF 'It closes the list.' "$state/reply.md" || fail "the quoted reply is written out: $(cat "$state/reply.md")"
ok "review-reply.sh answers a note in an unchanged file in the context file, quoting the lines it is about"

# The same question, with c.txt now changed 15 lines below it: the file is in the
# review, so the reply sits on its line there, however far from the change.
cp "$repo/c.txt" "$work/c.keep"
sed -i.bak 's/^c20$/c-twenty/' "$repo/c.txt"; rm -f "$repo/c.txt.bak"
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/replies.json" --path a.txt --path b.txt --path c.txt )
grep -qxF '## c.txt:5 ( )' "$state/notes.md" || fail "a reply far from its file's change sits on its line: $(cat "$state/notes.md")"
! grep -qxF '>    5  c5' "$state/reply.md" || fail "a reply in a changed file is not quoted: $(cat "$state/reply.md")"
cp "$work/c.keep" "$repo/c.txt"
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/replies.json" --path a.txt --path b.txt --path c.txt )
ok "review-reply.sh puts a reply on its line in a changed file, however far from the change"

# A reply about several lines is one note, on its first site, naming the rest:
# a pointer note at each other site lists one #N over and over.
jq '.replies[1].sites += [{"file": "a.txt", "line": 5}]' "$work/replies.json" > "$work/multi.json"
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/multi.json" --path a.txt --path b.txt --path c.txt )
[ "$(key NOTE_COUNT "$s")" = 2 ] || fail "a reply with two sites is still one note: $s"
[ "$(grep -c '^🤖 #2 ' "$state/notes.md")" = 1 ] || fail "one note heads reply 2: $(cat "$state/notes.md")"
! grep -q '^## a.txt:4 ' "$state/notes.md" || fail "the second site gets no note of its own: $(cat "$state/notes.md")"
grep -qxF 'Also at: a.txt:5' "$state/notes.md" || fail "the note names its other sites: $(cat "$state/notes.md")"
grep -qF "| 2 | rename b1 to beta | 🏁 as asked | \`b.txt:1\`, \`a.txt:5\` |" "$state/reply-head.md" || fail "the table names every site: $(cat "$state/reply-head.md")"
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/replies.json" --path a.txt --path b.txt --path c.txt )
ok "review-reply.sh seeds one note per reply, naming its other sites"

# Replies are numbered in the order revdiff lists them, by path then line, not
# by the order the comments came back in: with reply 1 on a.txt:5 and reply 2
# on a.txt:3, reply 2 is #1, and the off-diff replies follow the placed ones.
jq '.replies[0].sites = [{"file": "a.txt", "line": 5}] | .replies[1].sites = [{"file": "a.txt", "line": 3}]' "$work/replies.json" > "$work/order.json"
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/order.json" --path a.txt --path b.txt --path c.txt )
[ "$(grep '^🤖 #' "$state/notes.md" | cut -d' ' -f2)" = "$(printf '#1\n#2')" ] || fail "the notes count up in diff order: $(cat "$state/notes.md")"
[ "$(sed -n '/^## a.txt:2 /{n;p;}' "$state/notes.md")" = '🤖 #1 · 🏁 as asked' ] || fail "the first line in the diff is #1: $(cat "$state/notes.md")"
[ "$(grep -o '^| [0-9]* | [^|]*' "$state/reply-head.md")" = "$(printf '%s\n' '| 1 | rename b1 to beta ' '| 2 | why uppercase? ' '| 3 | shorter subject ' '| 4 | what is c5 for? ')" ] \
  || fail "the table runs in the notes' order: $(cat "$state/reply-head.md")"
[ "$(grep '^## #' "$state/reply.md")" = "$(printf '%s\n' '## #3 · ⚠️ done differently' '## #4 · answered')" ] || fail "the off-diff replies carry their numbers: $(cat "$state/reply.md")"
[ "$(wc -l < "$state/reply-head.md" | tr -d ' ')" = 7 ] || fail "the head is a title, one line of instructions, and the table: $(cat "$state/reply-head.md")"
s=$( cd "$repo" && bash "$seed" --state "$state" --replies "$work/replies.json" --path a.txt --path b.txt --path c.txt )
ok "review-reply.sh numbers the replies in the order the diff shows them"

# --- the reply review ------------------------------------------------------
export REVDIFF_ARGS_FILE="$work/args" REVDIFF_ENV_FILE="$work/env" REVDIFF_CONTEXT_CAPTURE="$work/context"
export REVDIFF_STUB_OUTPUT; REVDIFF_STUB_OUTPUT=$(cat "$state/notes.md")
o=$(run --reply "$state" 2>/dev/null)
grep -qxF "$reviewed" "$work/args" || fail "the reply diffs from the reviewed snapshot: $(cat "$work/args")"
grep -qxF -- "--annotations=$state/notes.md" "$work/args" || fail "the replies are preloaded: $(cat "$work/args")"
grep -qxF -- "--only=(context).md" "$work/args" || fail "the context file is in the tree: $(cat "$work/args")"
grep -qxF -- "--only=b.txt" "$work/args" || fail "a path changed since the review is in the tree: $(cat "$work/args")"
grep -qxF -- "--only=a.txt" "$work/args" || fail "a path holding a reply is in the tree: $(cat "$work/args")"
! grep -qxF -- "--only=c.txt" "$work/args" || fail "a path unchanged since the review stays out, its reply quoted in the context file: $(cat "$work/args")"
! grep -qxF REVDIFF_NO_TREE=true "$work/env" || fail "a reply with files beside the context file keeps the tree: $(cat "$work/env")"
[ "$(head -1 "$work/context")" = '# Add b' ] || fail "the context file opens with the header: $(head -3 "$work/context")"
[ "$(grep -n '^# Reply to your review$' "$work/context" | cut -d: -f1)" -gt "$(grep -n '^ original change' "$work/context" | cut -d: -f1)" ] \
  || fail "the reply follows the header and its stats: $(cat "$work/context")"
[ "$(grep -n '^| 4 | ' "$work/context" | cut -d: -f1)" -lt "$(grep -n '^╭─ Review' "$work/context" | cut -d: -f1)" ] \
  || fail "the reply table comes ahead of the Review box, its numbers in view: $(cat "$work/context")"
[ "$(grep -n '^# Replies with no line in the diff$' "$work/context" | cut -d: -f1)" -gt "$(grep -n '^Why b exists' "$work/context" | cut -d: -f1)" ] \
  || fail "the off-diff replies follow the message: $(cat "$work/context")"
[ "$(jq -r .raw.exitCode <<<"$(key REVIEW_OUTPUT "$o")")" = undecided ] || fail "replies returned as seeded are no feedback, and no verdict: $o"
[ -z "$(key REVIEW_STATE "$o")" ] || fail "a reply with no feedback saves no state: $o"
ok "--reply: diffs from the snapshot, preloads the replies, and reads them back as read"

[ "$(grep '^ [a-z]' "$work/context")" = "$(printf '%s\n' ' this round · 2 files' ' original change · 3 files')" ] \
  || fail "the stack runs from this round down to the change the first review saw, only this round coloured: $(cat "$work/context")"
[ "$(grep -c '^+.* [0-9]*$' "$work/context")" = 1 ] || fail "this round draws its added lines as an insertion: $(cat "$work/context")"
[ "$(grep -c '^ .* +[0-9]*$' "$work/context")" = 1 ] || fail "the original change draws its added lines as context, signed: $(cat "$work/context")"
ok "--reply: the context file stacks this round over the original change"

REVDIFF_STUB_OUTPUT=$(cat "$state/notes.md"; printf '\n\n## b.txt:2 (+)\nand b2?')
o=$(run --reply "$state")
j=$(key REVIEW_OUTPUT "$o")
[ "$(key REVIEW_VERDICT "$o")" = changes-requested ] || fail "a new note is feedback: $o"
[ "$(jq '.comments | length' <<<"$j")" = 1 ] || fail "only the new note is feedback: $j"
[ "$(jq -r '.comments[0].body' <<<"$j")" = 'and b2?' ] || fail "the new note: $j"
next=$(key REVIEW_STATE "$o")
{ [ -d "$next" ] && [ "$next" != "$state" ]; } || fail "a reply that draws feedback saves the next state: $o"
[ "$(jq length "$next/comments.json")" = 1 ] || fail "the next state carries only the feedback: $(cat "$next/comments.json")"
[ "$(cat "$next/earlier")" = "$reviewed" ] || fail "the next state carries the snapshots before it: $(cat "$next/earlier" 2>&1)"
ok "--reply: a new note is feedback, and saves the next round's state"

REVDIFF_STUB_OUTPUT=$(sed 's/^It names the constant.$/It names the constant. Which one?/' "$state/notes.md")
o=$(run --reply "$state"); j=$(key REVIEW_OUTPUT "$o")
[ "$(key REVIEW_VERDICT "$o")" = changes-requested ] || fail "an edited reply is feedback: $o"
grep -q 'Which one?' <<<"$(jq -r '.comments[0].body' <<<"$j")" || fail "the edited reply comes back whole: $j"
ok "--reply: an edited reply is feedback"

reply_at=$(grep -n '^# Reply to your review$' "$work/context" | cut -d: -f1)
REVDIFF_STUB_OUTPUT=$(printf '## (context).md:%s ( )\nthe table is too long' "$reply_at")
o=$(run --reply "$state"); j=$(key REVIEW_OUTPUT "$o")
[ "$(jq -r '.comments[0].target' <<<"$j")" = changeset ] || fail "a note on the reply answers the reply, not the message: $j"
msg_at=$(grep -n '^Why b exists' "$work/context" | cut -d: -f1)
REVDIFF_STUB_OUTPUT=$(printf '## (context).md:%s ( )\nsay why in full' "$msg_at")
o=$(run --reply "$state"); j=$(key REVIEW_OUTPUT "$o")
[ "$(jq -r '.comments[0].target' <<<"$j")" = commit-message ] || fail "a note on the message under the reply table is about the message: $j"
off_at=$(grep -n '^## #4 ' "$work/context" | cut -d: -f1)
REVDIFF_STUB_OUTPUT=$(printf '## (context).md:%s ( )\nwhy c5?' "$off_at")
o=$(run --reply "$state"); j=$(key REVIEW_OUTPUT "$o")
[ "$(jq -r '.comments[0].target' <<<"$j")" = changeset ] || fail "a note on an off-diff reply answers the reply: $j"
ok "--reply: a note on the reply's table is aimed at the changeset, and one on the message below it at the message"

# --- a reply that changed nothing still opens ---------------------------------
cat > "$work/answer.json" <<'EOF'
{"replies": [{"comment": 1, "status": "answered", "reply": "b2 stays."}]}
EOF
s=$( cd "$repo" && bash "$seed" --state "$next" --replies "$work/answer.json" --path a.txt --path b.txt --path c.txt )
export REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT=""
o=$(run --reply "$next" 2>/dev/null)
[ "$(jq -r .raw.exitCode <<<"$(key REVIEW_OUTPUT "$o")")" = undecided ] || fail "a reply with no change opens rather than reporting an empty range: $o"
[ "$(grep -c -- '^--only=\|^--include=' "$work/args")" = 1 ] || fail "an answer-only round shows the context file alone: $(cat "$work/args")"
grep -qxF REVDIFF_NO_TREE=true "$work/env" || fail "the context file alone opens without the tree, where revdiff would list its headings: $(cat "$work/env")"
[ "$(grep '^ [a-z]' "$work/context")" = "$(printf '%s\n' ' this round · no changes' ' after review 1 · 2 files' ' original change · 3 files')" ] \
  || fail "an answer-only round changed nothing, and the round before it keeps its size: $(cat "$work/context")"
ok "--reply: an answer-only round opens on an empty diff, the context file shown without the tree"

# --- refusals ----------------------------------------------------------------
rc=0; ( cd "$repo" && bash "$dispatch" HEAD --reply "$state" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 64 ] || fail "--reply on a range review should exit 64, got $rc"
git -C "$repo" add b.txt
printf 'beta\nb2\nb3\n' > "$repo/b.txt"
rc=0; ( cd "$repo" && bash "$dispatch" --local --staged-path b.txt --reply "$state" ) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 64 ] || fail "--reply with --staged-path should exit 64, got $rc"
ok "--reply answers a working-tree --local review only"
