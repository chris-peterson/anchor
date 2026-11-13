#!/usr/bin/env bash
# Functional test for `edit` mode (scripts/review/modes/edit.sh) and the two axes the
# dispatcher resolves — which mode a review runs in, and which tool runs it.
#
# Drives the real dispatcher with ANCHOR_EDITOR_LAUNCHER pointed at a stub that
# stands in for the user's edit: it rewrites, empties, or leaves the buffer
# alone, and can exit non-zero the way `:cq` does. Asserts the normalized DIFF
# contract the adapter emits, that what the editor saved comes back as the
# artifact, and that a buffer nobody saved is never read as approval. Requires
# jq.
set -euo pipefail

# Hermetic: ignore the user's global/system git config so tool selection is
# controlled per-case here, not by a global anchor.edit.tool.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dispatch="$here/../scripts/review-diff.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-editor-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub edit: the seam ANCHOR_EDITOR_LAUNCHER opens. It receives the buffer
# path, copies it aside so a case can assert what the user would have seen, and
# then acts out one of the four things a user does with an editor.
#   EDITOR_STUB_MODE=save    save without changing anything (the default)
#   EDITOR_STUB_MODE=replace write $EDITOR_STUB_TEXT as the whole artifact
#   EDITOR_STUB_MODE=empty   save an empty buffer
#   EDITOR_STUB_MODE=quit    leave without saving at all
# and $EDITOR_STUB_RC is the status it leaves with, so any of the four can be
# paired with the non-zero exit of vim's `:cq` or with the 124 a closed pane
# reports. `save` writes through a rename, which is how a real editor saves and
# what the adapter's write detection has to survive.
cat > "$bin/stub-editor.sh" <<'EOF'
#!/usr/bin/env bash
buffer="$1"
if [ -n "${EDITOR_BUFFER_CAPTURE:-}" ]; then
  cp "$buffer" "$EDITOR_BUFFER_CAPTURE"
  printf '%s\n' "$buffer" > "$EDITOR_BUFFER_CAPTURE.path"
fi
case "${EDITOR_STUB_MODE:-save}" in
  save)
    cp "$buffer" "$buffer.sav" && mv -f "$buffer.sav" "$buffer"
    ;;
  replace)
    scissors='------------------------ >8 ------------------------'
    rest=$(sed -En "/^(# )?${scissors}\$/,\$p" "$buffer")
    { printf '%s\n\n' "${EDITOR_STUB_TEXT:-}"; printf '%s\n' "$rest"; } > "$buffer"
    ;;
  empty) : > "$buffer" ;;
  quit)  : ;;
esac
exit "${EDITOR_STUB_RC:-0}"
EOF
chmod +x "$bin/stub-editor.sh"
export ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh"

# --- a git repo with something to review ------------------------------------
repo="$work/repo"
git init --quiet -b main "$repo"
git -C "$repo" config user.email "t@example.com"
git -C "$repo" config user.name "T"
git -C "$repo" config commit.gpgsign false
printf 'one\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m first
printf 'one\ntwo\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit --quiet -m second

# Hermetic in PATH as well as in git config. Availability reads what is
# installed, so without a fixed PATH the assertions would read the host's
# installed set rather than the resolution they are about. A stub revdiff ahead
# of everything makes revdiff present. It sits in its own dir, not $bin: the
# probe cases below run against $bin precisely to assert what happens when
# revdiff is not installed.
viewerbin="$work/viewerbin"; mkdir -p "$viewerbin"
# shellcheck disable=SC2016  # the stub's own $1, expanded when it runs
printf '#!/usr/bin/env bash\n[ "${1:-}" != --version ] || echo "version: v1.14.0"\nexit 0\n' > "$viewerbin/revdiff"; chmod +x "$viewerbin/revdiff"
run() { ( cd "$repo" && PATH="$viewerbin:$PATH" bash "$dispatch" "$@" ); }
verdict_of() { sed -n 's/^REVIEW_VERDICT=//p' <<<"$1"; }
json_of()    { sed -n 's/^REVIEW_OUTPUT=//p' <<<"$1"; }

# The proposed artifact of a two-path review — markdown, because three of the
# four artifacts anchor drafts are, and `#` must survive as a heading.
draft="$work/proposed.md"
printf '# Why this change\n\nThe reviewer needs the why first.\n' > "$draft"
prior="$work/prior.md"
printf '# Why this change\n\nStale text.\n' > "$prior"
# The other shape of a left-hand side: nothing to compare against. `blank` holds
# the newline a `> file` capture of an absent description leaves behind, which is
# the shape the default has to read as empty rather than as a prior version.
nothing="$work/nothing.md"; : > "$nothing"
blank="$work/blank.md"; printf '\n\n' > "$blank"

# An approved edit is written over the artifact file, so a case that approves a
# change reviews a copy, and `$draft` stays the fixture every other case reads.
# Every outcome but that one has to leave the artifact file byte for byte as
# drafted, which `untouched` holds it to.
draft_orig="$work/proposed.orig"; cp "$draft" "$draft_orig"
draft_copy() { cp "$draft_orig" "$work/$1.md"; printf '%s' "$work/$1.md"; }
untouched() { cmp -s "$draft" "$draft_orig" || fail "$1 wrote the draft file: $(cat "$draft")"; }

# --- saved unchanged -> approved, nothing edited ----------------------------
export EDITOR_STUB_MODE=save
export EDITOR_BUFFER_CAPTURE="$work/buffer.txt"
# An editor with no chords, named rather than left to the host's default, which
# is vi on one platform and something else on another.
o=$(GIT_EDITOR=plain-editor run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]                  || fail "unchanged -> $(verdict_of "$o"), want approved"
[ "$(jq -r .mode <<<"$j")" = edit ]                  || fail "mode should be edit"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ]       || fail "unchanged should edit nothing"
[ "$(jq '.comments|length' <<<"$j")" = 0 ]           || fail "edit mode carries no comments"
[ "$(jq -r .capabilities.editableDescription <<<"$j")" = true ] || fail "caps.editableDescription"
[ "$(jq -r .reviewCompleteness <<<"$j")" = null ]    || fail "completeness should be null"
untouched "an approval of the draft as drafted"
ok "edit: saved unchanged -> approved, no editedFields, the draft file byte for byte as drafted"

# The buffer is the artifact, then the scissors, then the change under review.
grep -qx '# Why this change' "$EDITOR_BUFFER_CAPTURE" || fail "markdown heading missing from buffer"
grep -q '>8' "$EDITOR_BUFFER_CAPTURE"                 || fail "scissors line missing from buffer"
grep -q 'Stale text' "$EDITOR_BUFFER_CAPTURE"         || fail "the diff against the prior file is not below the scissors"
grep -q '^│ Save to approve' "$EDITOR_BUFFER_CAPTURE"  || fail "what saving does is outlined: $(cat "$EDITOR_BUFFER_CAPTURE")"
grep -q 'To reject it, quit with exit code 1' "$EDITOR_BUFFER_CAPTURE" || fail "an editor with no chords names the reject status: $(cat "$EDITOR_BUFFER_CAPTURE")"
ok "edit: buffer is artifact + scissors + the change under review"

# The editor reads the name to pick its mode, so a markdown artifact opens under
# a `.md` buffer and markdown preview is a keystroke away.
[[ "$(cat "$EDITOR_BUFFER_CAPTURE.path")" == *.md ]] \
  || fail "a markdown artifact should open in a .md buffer, got $(cat "$EDITOR_BUFFER_CAPTURE.path")"
ok "edit: a markdown artifact opens in a .md buffer"

# The name is what an editor's status line shows, so it carries the repo, the
# branch, and the artifact; the directory around it is what keeps it unique.
buffer_path=$(cat "$EDITOR_BUFFER_CAPTURE.path")
[ "${buffer_path##*/}" = 'repo@main.description.md' ] \
  || fail "the buffer should be named for the repo, branch, and artifact, got ${buffer_path##*/}"
dir_name="${buffer_path%/*}"; dir_name="${dir_name##*/}"
[[ "$dir_name" == anchor-editor.?????? ]] || fail "the buffer should sit in a directory of its own, got $dir_name"
[ ! -e "${buffer_path%/*}" ] || fail "the buffer's directory outlived the review"
ok "edit: the buffer is named repo@branch.artifact, in a directory of its own"

EDITOR_BUFFER_CAPTURE="$work/named.txt" GIT_EDITOR=plain-editor \
  run --skill issue --mode edit --files "$prior" "$draft" --name 'acme#7' >/dev/null
buffer_path=$(cat "$work/named.txt.path")
[ "${buffer_path##*/}" = 'acme#7.md' ] || fail "--name should name the buffer, got ${buffer_path##*/}"
ok "edit: --name names the buffer for the object it edits"

# The draft opens on the first line. Below the scissors, the flow that opened
# the review and what approving hands it come first, and the diff names its
# sides rather than their temp paths.
[ "$(head -1 "$EDITOR_BUFFER_CAPTURE")" = '# Why this change' ] \
  || fail "the buffer should open on the draft: $(head -1 "$EDITOR_BUFFER_CAPTURE")"
below=$(sed -n '/>8/,$p' "$EDITOR_BUFFER_CAPTURE")
[ "$(grep -m1 -E '^  [a-z]' <<<"$below")" = '  opened by: /anchor:prepare-review' ] \
  || fail "the opening skill should lead the rows below the scissors: $below"
[ "$(grep -E '^(---|\+\+\+) ' <<<"$below")" = "$(printf '%s\n%s' '--- current' '+++ draft')" ] \
  || fail "the diff should label its sides current and draft: $below"
ok "edit: the draft opens on line 1; the opening skill leads the rows below the scissors"

# Helix starts in the buffer's own directory, so its status line shows the
# buffer's name. Any other editor gets the buffer alone.
cat > "$bin/stub-edit-runner.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$EDIT_RUNNER_CAPTURE"
eval "set -- $1"
for file; do :; done
cp "$file" "$file.sav" && mv -f "$file.sav" "$file"
EOF
chmod +x "$bin/stub-edit-runner.sh"
edit_via_runner() {
  ( unset ANCHOR_EDITOR_LAUNCHER
    git -C "$repo" config anchor.edit.tool "$1"
    ANCHOR_HOST_RUNNER="$bin/stub-edit-runner.sh" EDIT_RUNNER_CAPTURE="$work/edit-cmd" EDITOR_STUB_MODE=save \
      run --skill prepare-review --mode edit --files "$prior" "$draft" >/dev/null
    git -C "$repo" config --unset anchor.edit.tool )
}
edit_via_runner hx
eval "set -- $(cat "$work/edit-cmd")"
[[ "$#" -eq 4 && "$1" = hx && "$2" = -w && "$3" = "${4%/*}" ]] \
  || fail "helix should start in the buffer's directory: $(cat "$work/edit-cmd")"
edit_via_runner myed
eval "set -- $(cat "$work/edit-cmd")"
[ "$#" -eq 2 ] || fail "any other editor should get only the buffer: $(cat "$work/edit-cmd")"
export EDITOR_STUB_MODE=save
ok "edit: helix starts in the buffer's directory; any other editor gets the buffer alone"

# --- saved changed -> the saved text IS the artifact ------------------------
export EDITOR_STUB_MODE=replace
export EDITOR_STUB_TEXT='# Rewritten by hand

## A heading the editor added'
d=$(draft_copy changed)
prior_bytes=$(cat "$prior")
o=$(run --skill prepare-review --mode edit --files "$prior" "$d"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "changed -> $(verdict_of "$o"), want approved"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = description ] || fail "target should be description"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] \
  || fail "edited text not adopted verbatim: $(jq -c '.editedFields[0].edited' <<<"$j")"
[ "$(jq -r '.editedFields[0].original' <<<"$j")" = "$(cat "$draft_orig")" ] || fail "original not carried"
[[ "$(jq -r '.editedFields[0].edited' <<<"$j")" != *'>8'* ]] || fail "context leaked past the scissors"
[ "$(cat "$d")" = "$EDITOR_STUB_TEXT" ] || fail "the draft file should hold the approved text: $(cat "$d")"
[ "$(cat "$prior")" = "$prior_bytes" ] || fail "the left-hand side is context, never written: $(cat "$prior")"
ok "edit: saved changed -> approved, edited text adopted verbatim (markdown intact) and written over the draft file"

# The report behind DIFF-13's write-back: a paragraph the author deleted and
# saved reached the CR anyway, because the CR was opened from the draft file.
two="$work/two-paragraphs.md"
printf '# Why this change\n\nKeep this paragraph.\n\nThe paragraph the author removes.\n' > "$two"
o=$(EDITOR_STUB_TEXT=$'# Why this change\n\nKeep this paragraph.' \
    run --skill prepare-review --mode edit --files "$nothing" "$two"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "a removed paragraph -> $(verdict_of "$o"), want approved"
[ "$(grep -c 'The paragraph the author removes' "$two")" = 0 ] \
  || fail "the removed paragraph is still in the draft file: $(cat "$two")"
grep -q 'Keep this paragraph' "$two" || fail "the kept paragraph should stay: $(cat "$two")"
ok "edit: a paragraph removed and saved is gone from the --files draft file"

# A file the approved text cannot be written to is an error the caller sees,
# with the text it could not write still in hand. Root writes through a
# read-only mode, so there the case has nothing to hold.
ro=$(draft_copy readonly); chmod 444 "$ro"
if [ -w "$ro" ]; then
  echo "ok - # SKIP write-failed: a read-only file is writable here"
else
  o=$(run --skill prepare-review --mode edit --files "$prior" "$ro" 2>"$work/err.txt"); j=$(json_of "$o")
  chmod 644 "$ro"
  [ "$(verdict_of "$o")" = no-verdict ] || fail "an unwritable draft -> $(verdict_of "$o"), want no-verdict"
  [ "$(jq -r .raw.exitCode <<<"$j")" = write-failed ] || fail "raw.exitCode should be write-failed: $(jq -c .raw <<<"$j")"
  [ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] || fail "the approved text should ride back: $j"
  grep -q "could not be written to $ro" "$work/err.txt" || fail "stderr should name the file: $(cat "$work/err.txt")"
  cmp -s "$ro" "$draft_orig" || fail "the unwritable draft changed: $(cat "$ro")"
  ok "edit: an approved edit that cannot be written -> no-verdict, write-failed, the text in editedFields"
fi

# --- emptied -> rejected ----------------------------------------------------
export EDITOR_STUB_MODE=empty
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = rejected ] || fail "emptied -> $(verdict_of "$o"), want rejected"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ] || fail "a rejection edits nothing"
untouched "an emptied buffer"
ok "edit: emptied buffer -> rejected, the draft file untouched"

# --- exit 1 (ZQ, :cq) -> rejected, whatever was saved -----------------------
o=$(EDITOR_STUB_MODE=replace EDITOR_STUB_RC=1 run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = rejected ] || fail "exit 1 -> $(verdict_of "$o"), want rejected"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ] || fail "a rejection edits nothing"
untouched "a rejection after an edit"
ok "edit: exit 1 -> rejected, an edit saved first left out of the draft file"

# --- quit without saving -> undecided, asked about --------------------------
export EDITOR_STUB_MODE=quit
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft" 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]             || fail "quit unsaved -> $(verdict_of "$o"), want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = undecided ]  || fail "raw.exitCode should be undecided, got $(jq -c .raw <<<"$j")"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ]    || fail "an unanswered review edits nothing"
grep -q 'no verdict chosen' "$work/err.txt"       || fail "stderr should say no verdict was chosen"
untouched "a review closed without saving"
ok "edit: quit without saving -> no-verdict, undecided, the draft file untouched"

# --- a GUI editor missing its wait flag is not the reviewer declining --------
# Both cases write nothing, so they are indistinguishable at the buffer. Only
# one of them has something the user can do about it, and reporting the other's
# wording attributes a decision they were never offered (DIFF-14).
git -C "$repo" config anchor.edit.tool code
export EDITOR_STUB_MODE=quit
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft" 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "no wait flag -> $(verdict_of "$o"), want no-verdict"
grep -q -- '--wait' "$work/err.txt"   || fail "stderr should name the flag: $(cat "$work/err.txt")"
[ "$(jq -r .raw.exitCode <<<"$j")" = unsaved ] || fail "still the unsaved class, nothing was written"
[[ "$(jq -r .raw.output <<<"$j")" == *'--wait'* ]] \
  || fail "raw.output should name the flag, got $(jq -r .raw.output <<<"$j")"
grep -q 'no verdict chosen' "$work/err.txt" && fail "the undecided wording should not fire here"
# Invoked with the flag, an unsaved buffer is the reviewer's own choice again.
git -C "$repo" config anchor.edit.tool 'code --wait'
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft" 2>"$work/err.txt")
grep -q 'no verdict chosen' "$work/err.txt" || fail "with the flag set, the reviewer chose nothing: $(cat "$work/err.txt")"
git -C "$repo" config --unset anchor.edit.tool
ok "edit: a GUI editor that returned without waiting names the flag it needs"

# --- exited non-zero -> abort ----------------------------------------------
# Saved first, so the status alone is what keeps the edit out of the draft file.
export EDITOR_STUB_MODE=replace EDITOR_STUB_RC=4
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]    || fail "editor failure -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = 4 ] || fail "raw.exitCode should carry the editor's status"
untouched "an editor that exited non-zero"
ok "edit: non-zero editor exit -> no-verdict, status in raw.exitCode, the draft file untouched"
unset EDITOR_STUB_RC

# The terminal the editor was drawing in went away before it could answer —
# closing the review pane rather than quitting the editor. That is the host's
# failure, not a status the editor returned, so it comes back named. Driven
# through the launcher seam by returning the split runner's own code, which is
# also the one case a real editor could imitate by exiting 124 itself.
export EDITOR_STUB_MODE=quit EDITOR_STUB_RC=124
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft" 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]                || fail "a closed pane -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = pane-closed ]   || fail "raw.exitCode should name the cause, got $(jq -c .raw <<<"$j")"
grep -q 'before anything was saved' "$work/err.txt"  || fail "the remedy should reach stderr"
untouched "a pane closed before a save"
ok "edit: a closed review pane -> no-verdict, cause named rather than numbered, the draft file untouched"

# But the pane closing after a save is not that case: the reviewer answered and
# the answer is on disk, so it is graded like any other save rather than thrown
# away with the terminal that was drawing it.
export EDITOR_STUB_MODE=replace EDITOR_STUB_RC=124
export EDITOR_STUB_TEXT='# Saved, then the pane went away'
d=$(draft_copy pane-closed)
o=$(run --skill prepare-review --mode edit --files "$prior" "$d"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "saved then pane closed -> $(verdict_of "$o"), want approved"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] \
  || fail "the saved text should survive the pane, got $(jq -c '.editedFields[0].edited' <<<"$j")"
[ "$(cat "$d")" = "$EDITOR_STUB_TEXT" ] || fail "the saved text should reach the draft file: $(cat "$d")"
ok "edit: saved, then the pane closed -> approved, the saved text survives into the draft file"
unset EDITOR_STUB_RC EDITOR_STUB_TEXT
export EDITOR_STUB_MODE=save

# And with no host at all, the editor was never asked — a third cause, kept
# apart from the two above so none of them is reported as the others. PATH is
# pinned to the stubs: inherit the developer's and the ladder finds their real
# VS Code, whose `gui` host needs no terminal — the case then launches an editor
# for real and waits for someone to close it.
o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER='' TMUX='' \
     ITERM_SESSION_ID='' AGTERM_SESSION_ID='' ANCHOR_HOST_RUNNER='' GIT_EDITOR=true \
     bash "$dispatch" --skill prepare-review --mode edit \
     --files "$prior" "$draft" </dev/null 2>/dev/null ); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]            || fail "nowhere to open -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = no-host ]   || fail "raw.exitCode should be no-host, got $(jq -c .raw <<<"$j")"
untouched "a review with nowhere to open"
ok "edit: nowhere to open the editor -> no-verdict, no-host"

# --- a drafted commit message rides the same path --------------------------
export EDITOR_STUB_MODE=replace
export EDITOR_STUB_TEXT='Rewrite the subject

And the body the user typed.'
msg="$work/msg.txt"; printf 'Add a feature\n\nThe body explains why.\n' > "$msg"
msg_orig="$work/msg.orig"; cp "$msg" "$msg_orig"
msg_copy() { cp "$msg_orig" "$work/$1.txt"; printf '%s' "$work/$1.txt"; }
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
m=$(msg_copy changed)
o=$(run --skill commit --mode edit --local --message-file "$m"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "message edit -> $(verdict_of "$o")"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = commit-message ] || fail "target should be commit-message"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] || fail "edited message not adopted"
[ "$(cat "$m")" = "$EDITOR_STUB_TEXT" ] || fail "the message file should hold the approved message: $(cat "$m")"
grep -q 'three' "$EDITOR_BUFFER_CAPTURE" || fail "staged diff should sit below the scissors"
ok "edit: --message-file -> editedFields[commit-message] and the message file, diff below the scissors"

# The same report through a commit message: a paragraph removed and saved is
# gone from the file commit.sh commits from.
m="$work/two-paragraphs.txt"
printf 'Add a feature\n\nKeep this paragraph.\n\nThe paragraph the author removes.\n' > "$m"
o=$(EDITOR_STUB_TEXT=$'Add a feature\n\nKeep this paragraph.' \
    run --skill commit --mode edit --local --message-file "$m"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "a removed paragraph -> $(verdict_of "$o"), want approved"
[ "$(grep -c 'The paragraph the author removes' "$m")" = 0 ] \
  || fail "the removed paragraph is still in the message file: $(cat "$m")"
ok "edit: a paragraph removed and saved is gone from the --message-file message file"

# Anything short of approval leaves the message file as drafted.
o=$(EDITOR_STUB_MODE=empty run --skill commit --mode edit --local --message-file "$msg"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = rejected ] || fail "an emptied message -> $(verdict_of "$o"), want rejected"
o=$(EDITOR_STUB_RC=4 run --skill commit --mode edit --local --message-file "$msg"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "an editor exiting 4 -> $(verdict_of "$o"), want no-verdict"
cmp -s "$msg" "$msg_orig" || fail "a review short of approval wrote the message file: $(cat "$msg")"
ok "edit: an emptied or failed message review leaves the message file untouched"

# the diff below the scissors covers the named paths only, not a peer's edit
printf 'peer\n' > "$repo/peer.txt"
git -C "$repo" add peer.txt
git -C "$repo" commit --quiet -m peer
printf 'peer\nin flight\n' > "$repo/peer.txt"
o=$(run --skill commit --mode edit --local --message-file "$(msg_copy path)" --path a.txt)
grep -q 'three' "$EDITOR_BUFFER_CAPTURE" || fail "the named path's diff should be in the buffer"
! grep -q 'in flight' "$EDITOR_BUFFER_CAPTURE" || fail "a peer's edit outside --path should not be in the buffer"
git -C "$repo" checkout --quiet -- peer.txt
ok "edit: the buffer's diff covers only --path"

# git's own shape, so the editor's gitcommit mode greys the context: the buffer
# named the way git names it, under the repo and branch, and git's scissors with
# the context commented below it.
[[ "$(cat "$EDITOR_BUFFER_CAPTURE.path")" == */repo@main/COMMIT_EDITMSG ]] \
  || fail "a commit message should open in repo@main/COMMIT_EDITMSG, got $(cat "$EDITOR_BUFFER_CAPTURE.path")"
grep -qxF '# ------------------------ >8 ------------------------' "$EDITOR_BUFFER_CAPTURE" \
  || fail "a commit buffer should carry git's scissors: $(cat "$EDITOR_BUFFER_CAPTURE")"
grep -qxF '#   opened by: /anchor:commit' "$EDITOR_BUFFER_CAPTURE" \
  || fail "the context below a commit's scissors should be commented: $(cat "$EDITOR_BUFFER_CAPTURE")"
ok "edit: a commit message opens as git's COMMIT_EDITMSG, its context commented"

# The seeded message is the editable region, so it is not repeated as a header row.
[ "$(grep -c 'The body explains why' "$EDITOR_BUFFER_CAPTURE")" = 1 ] \
  || fail "the message body appears twice in the buffer"
ok "edit: the seeded message body is not duplicated in the header"

# A markdown draft keeps `#` for headings, so its context is an HTML comment.
o=$(run --skill prepare-review --mode edit --files "$prior" "$(draft_copy comment)")
[ "$(sed -n '/>8/{n;p;}' "$EDITOR_BUFFER_CAPTURE")" = '<!--' ] \
  || fail "a markdown draft's context should open a comment under the scissors: $(cat "$EDITOR_BUFFER_CAPTURE")"
grep -qxF -- '-->' "$EDITOR_BUFFER_CAPTURE" || fail "the comment should close before the diff"
ok "edit: a markdown draft's context sits in an HTML comment"

# --- the artifact target follows the invoking skill ------------------------
export EDITOR_STUB_MODE=replace EDITOR_STUB_TEXT='## Issue body'
o=$(run --skill issue --mode edit --files "$prior" "$(draft_copy issue)"); j=$(json_of "$o")
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = issue-body ] || fail "issue -> issue-body"
o=$(run --skill release --mode edit --files "$prior" "$(draft_copy release)"); j=$(json_of "$o")
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = release-notes ] || fail "release -> release-notes"
ok "edit: editedFields target follows --skill"

# --- a diff with no drafted artifact has nothing to edit -------------------
export EDITOR_STUB_MODE=save
o=$(run --skill commit --mode edit --previous 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "diff-only review -> want no-verdict"
grep -q 'diff' "$work/err.txt" || fail "the cause should name the mode that shows a diff"
ok "edit: a diff-only review -> no-verdict, cause on stderr"

# ====================== per-skill mode selection ===========================
unset ANCHOR_EDITOR_LAUNCHER
export EDITOR_STUB_MODE=save

# A stub split runner, so a revdiff review resolves without opening a pane.
cat > "$bin/stub-host-runner.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/stub-host-runner.sh"
export ANCHOR_HOST_RUNNER="$bin/stub-host-runner.sh"

mode_of()    { jq -r .mode    <<<"$(json_of "$1")"; }
tool_of() { jq -r .tool <<<"$(json_of "$1")"; }

# The mode has no key: the subject answers, whatever a user may have set and
# whichever skill is asking. Only --mode moves it, which is how a probe hands its
# answer to the launch.
git -C "$repo" config anchor.reviewMode edit
git -C "$repo" config anchor.commit.reviewMode edit
for skill in commit prepare-review issue release; do
  [ "$(mode_of "$(run --skill "$skill" --previous 2>/dev/null)")" = diff ] \
    || fail "$skill: a git range is a diff subject, and no key may say otherwise"
done
[ "$(mode_of "$(run --previous)")" = diff ] || fail "no --skill: still the subject's answer"
git -C "$repo" config --unset anchor.reviewMode || true
git -C "$repo" config --unset anchor.commit.reviewMode || true
ok "mode: the subject decides it, and no config key overrides that"

# The two axes are independent: the mode says edit/diff, the tool names the
# tool. A diff-mode run reports the viewer, an edit-mode run reports the editor.
[ "$(tool_of "$(run --skill commit --previous)")" = revdiff ] \
  || fail "a diff-mode run should report the viewer as its tool"
export ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh"
b=$(tool_of "$(GIT_EDITOR='my-editor --wait' run --skill commit --mode edit --local --message-file "$msg" 2>/dev/null)")
[ "$b" = 'my-editor --wait' ] || fail "an edit-mode run should report the editor as its tool, got '$b'"
unset ANCHOR_EDITOR_LAUNCHER
ok "mode: the tool names the tool that ran the mode, editor or viewer"

# anchor.edit.tool names edit mode's tool, above git's chain because it is the
# narrower statement.
export ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh"
git -C "$repo" config anchor.edit.tool 'anchor-editor --wait'
b=$(tool_of "$(GIT_EDITOR='my-editor --wait' run --skill commit --mode edit --local --message-file "$msg" 2>/dev/null)")
[ "$b" = 'anchor-editor --wait' ] || fail "anchor.edit.tool should outrank git's chain, got '$b'"
git -C "$repo" config --unset anchor.edit.tool || true
unset ANCHOR_EDITOR_LAUNCHER
ok "tool: anchor.edit.tool names edit mode's tool, over git's chain"

# --- an unknown mode fails rather than picking one -------------------------
if run --skill commit --mode bogus --previous 2>/dev/null; then fail "unknown mode should exit non-zero"; fi
ok "mode: an unknown mode exits non-zero"

# --- a key naming another viewer moves nothing: the review runs revdiff.
git -C "$repo" config anchor.diff.tool bogus-viewer
v=$( ( cd "$repo" && PATH="$bin:/usr/bin:/bin" bash "$dispatch" --skill commit --previous ) 2>/dev/null )
[ "$(tool_of "$v")" = revdiff ] \
  || fail "anchor.diff.tool naming another viewer should still run revdiff, got $(tool_of "$v")"
git -C "$repo" config --unset anchor.diff.tool || true
ok "tool: a diff review runs revdiff whatever anchor.diff.tool names"

# ====================== the probe ==========================================
# The skills ask how a review resolves before deciding whether a visual review is
# available at all, so the resolution lives here rather than in skill prose.
key_of() { sed -n "s/^$1=//p" <<<"$2"; }

# The probe answers "what is installed", so these cases run against a PATH this
# test controls rather than whatever the developer happens to have. `git` is all
# the probe itself needs, so the system dirs are enough alongside the stubs.
#
# The editor axis is pinned to "nothing to open", so these cases don't read the
# developer's own EDITOR or whether they ran the suite from a terminal. A no-op
# GIT_EDITOR is not enough on its own — the chain continues past git's own rungs
# (DIFF-16), so on a stock machine it still lands on a compiled default. What is
# deterministic on every platform is the *host* half: with no tmux, no iTerm2,
# and stdin off a terminal, a resolved editor has nowhere to render, which is
# what DIFF-17 reports as unavailable. The cases wanting the other answer set
# ANCHOR_EDITOR_LAUNCHER, which stands in for both halves.
probe() {
  ( cd "$repo" && PATH="$bin:/usr/bin:/bin" GIT_EDITOR=true TMUX='' \
      ITERM_SESSION_ID='' AGTERM_SESSION_ID='' ANCHOR_HOST_RUNNER='' \
      bash "$dispatch" "$@" </dev/null )
}

# The same, with a host supplied. `diff` needs one as much as `edit` does, so a
# case about the *tool* axis has to hold the host axis open or it measures the
# wrong thing.
probe_hosted() {
  ( cd "$repo" && PATH="$bin:/usr/bin:/bin" GIT_EDITOR=true TMUX='' \
      ITERM_SESSION_ID='' AGTERM_SESSION_ID='' ANCHOR_HOST_RUNNER="$bin/stub-host-runner.sh" \
      bash "$dispatch" "$@" </dev/null )
}

o=$(probe --skill commit --probe --mode edit)
[ "$(key_of REVIEW_MODE "$o")" = edit ]          || fail "--probe should report the configured mode"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ]        || fail "edit mode with no editor to open is not available"
[ "$(key_of REVIEW_EDIT_AVAILABLE "$o")" = 0 ]   || fail "no editor resolves, so the edit rung is not offerable"
ok "probe: a selected edit mode reports unavailable with nowhere to open one"

# The edit axis is reported on every probe, not only when edit mode is selected:
# it is what a skill offers as the rung below a viewer that is missing or died.
o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" \
     bash "$dispatch" --skill commit --probe --mode edit )
[ "$(key_of REVIEW_AVAILABLE "$o")" = 1 ]      || fail "a reachable editor makes a selected edit mode available"
[ "$(key_of REVIEW_EDIT_AVAILABLE "$o")" = 1 ] || fail "a reachable editor should be reported as offerable"
[ "$(key_of REVIEW_HOST "$o")" = launcher ]    || fail "the probe names where the review opens: $o"
ok "probe: a reachable editor is reported on its own axis, with where it opens"

o=$(probe_hosted --skill commit --probe --mode diff)
[ "$(key_of REVIEW_HOST "$o")" = launcher ] || fail "a diff probe names the host the viewer opens in: $o"
o=$(probe --skill commit --probe --mode edit)
grep -qx 'REVIEW_HOST=' <<<"$o" || fail "with nowhere to open, the host is reported empty: $o"
ok "probe: REVIEW_HOST names where the review opens in either mode, and is empty when nowhere can"

# Whether what is about to open is something the user chose (UX-07). The mode
# here comes from a config key and the editor from anchor's own ladder, so the
# launch has a hint to print for one and not the other.
[ "$(key_of REVIEW_MODE_SOURCE "$o")" = override ]   || fail "an asked-for mode should report source=override"
[ "$(key_of REVIEW_TOOL_SOURCE "$o")" = default ] || fail "an unconfigured editor should report source=default"
[ -n "$(key_of REVIEW_TOOL "$o")" ]               || fail "the probe should name the tool it would open"
ok "probe: the mode and the tool each report whether the user chose them"

o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" \
     GIT_EDITOR='my-editor --wait' bash "$dispatch" --skill commit --probe --mode edit )
[ "$(key_of REVIEW_TOOL "$o")" = 'my-editor --wait' ] || fail "a configured editor should be named verbatim"
[ "$(key_of REVIEW_TOOL_SOURCE "$o")" = config ]      || fail "a configured editor should report source=config"
ok "probe: a configured editor is named, and reported as the user's choice"

# One tool axis, whichever mode is on: a diff-mode probe names the viewer
# where an edit-mode one names the editor, so a consumer reads one key.
o=$( cd "$repo" && PATH="$viewerbin:$bin:/usr/bin:/bin" bash "$dispatch" --skill commit --probe )
[ "$(key_of REVIEW_MODE "$o")" = diff ]       || fail "the viewer mode should be what opens here"
[ "$(key_of REVIEW_TOOL "$o")" = revdiff ] || fail "a diff-mode probe should name the viewer"
ok "probe: the tool key names the viewer in diff mode and the editor in edit"

o=$(probe --skill commit --probe)
[ "$(key_of REVIEW_TOOL "$o")" = revdiff ]   || fail "probe should report revdiff"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ]    || fail "an absent binary should report unavailable"
ok "probe: with revdiff not installed, the probe reports unavailable"

# revdiff is what opens, and no key chose it.
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "version: ${REVDIFF_STUB_VERSION:-v1.14.0}"; exit 0; }
exit 0
EOF
chmod +x "$bin/revdiff"
o=$(probe_hosted --skill commit --probe)
[ "$(key_of REVIEW_TOOL "$o")" = revdiff ]          || fail "revdiff should be what opens"
[ "$(key_of REVIEW_TOOL_SOURCE "$o")" = required ]  || fail "no key chooses revdiff, so source=required"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 1 ]           || fail "an installed viewer with a host is available"
ok "probe: revdiff is the one reported, as required rather than chosen"

# The other half of the same question. Both modes need a program *and* somewhere
# to draw it, so a viewer that is plainly installed reports unavailable where
# there is no terminal to render it in — the answer that keeps a consumer from
# launching into a host problem it was never warned about.
o=$(probe --skill commit --probe)
[ "$(key_of REVIEW_TOOL "$o")" = revdiff ]  || fail "the installed viewer should still be named"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ]      || fail "an installed viewer with nowhere to render is not available"
ok "probe: a viewer with no host reports unavailable, as an editor does"

# A missing revdiff never flips the mode to edit, which edits one artifact
# rather than showing a diff.
rm -f "$bin/revdiff"
o=$(probe_hosted --skill commit --probe)
[ "$(key_of REVIEW_MODE "$o")" = diff ]          || fail "a missing revdiff should never flip the mode to edit"
[ "$(key_of REVIEW_TOOL "$o")" = revdiff ]       || fail "revdiff stays named"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ]        || fail "a missing revdiff cannot open"
key_of REVIEW_UNUSABLE "$o" | grep -qF 'install it from https://github.com/umputun/revdiff#installation' \
  || fail "the probe names the install: $o"
ok "probe: a missing revdiff is reported with its install, and never becomes edit mode"

# --mode drives the review directly, over what the subject would have picked.
export ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" EDITOR_STUB_MODE=save
o=$(run --skill commit --mode edit --files "$prior" "$draft")
[ "$(jq -r .mode <<<"$(json_of "$o")")" = edit ] || fail "--mode should outrank the subject"
o=$(run --skill commit --mode edit --probe)
[ "$(key_of REVIEW_MODE "$o")" = edit ]            || fail "--mode should drive the probe too"
[ "$(key_of REVIEW_MODE_SOURCE "$o")" = override ] || fail "--mode should report source=override"
unset ANCHOR_EDITOR_LAUNCHER
ok "mode: --mode outranks the subject, for the probe and the launch"

# The probe reports; it never opens anything.
export EDITOR_BUFFER_CAPTURE="$work/never.txt"
rm -f "$EDITOR_BUFFER_CAPTURE"
probe --skill commit --probe >/dev/null
[ ! -f "$EDITOR_BUFFER_CAPTURE" ] || fail "--probe should launch nothing"
ok "probe: --probe launches nothing"

# The superseded key does nothing, and is said to do nothing — a config written
# against it is neither silently obeyed nor silently ignored.
git -C "$repo" config anchor.reviewBackend editor
o=$( cd "$repo" && PATH="$viewerbin:$bin:/usr/bin:/bin" \
     bash "$dispatch" --skill commit --probe 2>"$work/legacy.txt" )
[ "$(key_of REVIEW_MODE "$o")" = diff ]            || fail "the superseded key must not move the mode"
grep -q 'anchor.edit.tool' "$work/legacy.txt"   || fail "the key that replaced it should be named on stderr"
grep -q 'diff reviews open in revdiff' "$work/legacy.txt" || fail "the viewer should be named on stderr"
git -C "$repo" config --unset anchor.reviewBackend || true
ok "mode: the superseded anchor.reviewBackend key does nothing, and says so"
unset EDITOR_BUFFER_CAPTURE

# ====================== the subject-picked mode (CONFIG-15) ================
# The mode follows what the review is about, and there is no key that says
# otherwise — only whether the shape it picked can actually open.
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "version: ${REVDIFF_STUB_VERSION:-v1.14.0}"; exit 0; }
exit 0
EOF
chmod +x "$bin/revdiff"

# The default reads the subject, not the skill that asked — so the same skill
# lands in either tool depending on what it is about to review, and every skill
# lands in the same one for the same subject.
for skill in prepare-review issue release commit review; do
  for left in "$nothing" "$blank"; do
    o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" \
         bash "$dispatch" --skill "$skill" --probe --files "$left" "$draft" )
    [ "$(key_of REVIEW_MODE "$o")" = edit ] \
      || fail "$skill with nothing to diff against should default to edit mode"
  done
done
ok "default: one file with no prior version opens the editor, whichever skill asked"

for skill in prepare-review issue release commit review; do
  o=$(probe --skill "$skill" --probe --files "$prior" "$draft")
  [ "$(key_of REVIEW_MODE "$o")" = diff ] \
    || fail "$skill with a prior version to diff against should default to diff mode"
done
ok "default: a subject with a prior version opens the diff viewer, whichever skill asked"

for skill in commit review; do
  o=$(probe --skill "$skill" --probe)
  [ "$(key_of REVIEW_MODE "$o")" = diff ] || fail "a git range names a base, so it should default to diff mode"
done
ok "default: a git range opens the diff viewer with nothing configured"

# The mode gives way (DIFF-11) only to a `diff` review that can actually open,
# and both modes now draw from one host set — so with no terminal anywhere there
# is nothing to give way to, and the subject's `edit` is kept. Keeping it is the
# more useful answer: its report names the editor problem, where a give-way would
# trade it for a viewer problem the user is no closer to fixing.
o=$(probe --skill prepare-review --probe --files "$nothing" "$draft")
[ "$(key_of REVIEW_MODE "$o")" = edit ]        || fail "with no host for either mode, the subject's edit should be kept"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ]      || fail "kept, and reported unavailable"
[ "$(key_of REVIEW_EDIT_AVAILABLE "$o")" = 0 ] || fail "the edit axis should say the editor rung is out too"
ok "default: with nowhere to open either mode, the subject's mode is kept"

# Given a host, the subject's `edit` reaches an editor, so there is no occasion
# to give way at all.
o=$(probe_hosted --skill prepare-review --probe --files "$nothing" "$draft")
[ "$(key_of REVIEW_MODE "$o")" = edit ]   || fail "a reachable editor should keep the subject's edit mode"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 1 ] || fail "an editor with a host is available"
ok "default: a single file with a host to open it in stays in edit mode"

# A *configured* one is kept and reports the missing piece itself.
o=$(probe --skill prepare-review --probe --mode edit --files "$prior" "$draft")
[ "$(key_of REVIEW_MODE "$o")" = edit ]   || fail "an asked-for edit mode should be kept, not swapped for a viewer"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ] || fail "kept, and reported unavailable"
ok "mode: a mode asked for with --mode is kept even with nowhere to open it"

# ====================== the resolution chain (DIFF-16) =====================
# Asserted on the lib directly: the rungs past git's own are anchor's, and a
# launch would only show which one won.
cat > "$bin/resolve-editor.sh" <<EOF
#!/usr/bin/env bash
source "$here/../scripts/lib/review-editor.sh"
printf '%s' "\$(anchor_editor_resolve)"
EOF
chmod +x "$bin/resolve-editor.sh"

codebin="$work/codebin"
mkdir -p "$codebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$codebin/code"
chmod +x "$codebin/code"

# TERM is pinned per case rather than inherited: git names no editor at all on a
# dumb terminal, and a CI step and Claude Code's Bash tool both run without one,
# so a suite that reads whatever TERM the developer has passes here and fails
# there. Every host signal is pinned for the same reason — which rung anchor
# picks turns on whether a terminal can be hosted, so a suite that inherits the
# developer's iTerm2 session reads a different ladder than CI does. `</dev/null`
# takes the `tty` host out along with them.
resolve() {
  ( cd "$repo" && PATH="$1:/usr/bin:/bin" TERM="${2-dumb}" GIT_EDITOR=true \
      TMUX='' ANCHOR_EDITOR_LAUNCHER='' ITERM_SESSION_ID='' AGTERM_SESSION_ID='' \
      ANCHOR_HOST_RUNNER="${3-}" bash "$bin/resolve-editor.sh" </dev/null )
}

# With a terminal to host, the editor a plain `git commit` opens wins over a
# GUI editor anchor merely found: it renders in the pane anchor labels and
# focuses, where VS Code opens a window behind the terminal.
r=$(resolve "$codebin" dumb "$bin/stub-host-runner.sh")
[ -n "$r" ] || fail "git's compiled default should resolve with a terminal host"
[ "$r" != "code --wait" ] || fail "a hostable terminal should outrank the GUI rung, got '$r'"
case "$r" in true|:|*/true) fail "a no-op compiled default should be discounted" ;; esac
ok "resolve: with a terminal host, git's own compiled default"

# And with nowhere to put a terminal, the GUI rung is the only one that reaches
# anything at all.
r=$(resolve "$codebin")
[ "$r" = "code --wait" ] || fail "with no terminal host, a blocking VS Code should be reached, got '$r'"
ok "resolve: with nowhere to host one, a blocking VS Code on PATH"

# The same, with GIT_EDITOR unset and a real terminal type, as any caller other
# than Claude Code has it. git would answer its compiled default there, which
# must not read as an editor the user configured (DIFF-16).
r=$( cd "$repo" && env -u GIT_EDITOR -u VISUAL -u EDITOR PATH="$codebin:/usr/bin:/bin" \
       TERM=xterm-256color TMUX='' ANCHOR_EDITOR_LAUNCHER='' ITERM_SESSION_ID='' \
       ANCHOR_HOST_RUNNER='' bash "$bin/resolve-editor.sh" </dev/null )
[ "$r" = "code --wait" ] || fail "an unset GIT_EDITOR should still reach the GUI rung, got '$r'"
ok "resolve: an unset GIT_EDITOR under a real TERM is not read as configured"

# A dumb terminal is git's answer about the stdio git itself was handed. This
# tool puts the editor in a terminal the host opens (DIFF-17), which is a
# separate question, so the rung stands either way.
for term in dumb xterm; do
  r=$(resolve "$work/empty-bin" "$term")
  [ -n "$r" ] || fail "git's own compiled default should still resolve (TERM=$term)"
  case "$r" in true|:|*/true) fail "a no-op compiled default should be discounted (TERM=$term)" ;; esac
done
ok "resolve: with neither, the compiled default still names the editor"

# The no-op scrub reaches this rung's inputs too (DIFF-16): a harness that
# exports EDITOR=true would otherwise hand git a value git happily reports, and
# an editor that opens nothing reads as an artifact the user approved.
r=$( cd "$repo" && PATH="$work/empty-bin:/usr/bin:/bin" TERM=xterm \
     EDITOR=true VISUAL=true GIT_EDITOR=true bash "$bin/resolve-editor.sh" )
[ -n "$r" ] || fail "a no-op EDITOR should not swallow git's compiled default"
ok "resolve: a no-op EDITOR leaves the compiled default reachable"

# A no-op core.editor is discounted the same way, and git's compiled default is
# read past it: `git var GIT_EDITOR` reports a configured `true` as the editor,
# and an empty one as no editor at all, so neither can be how the rung asks.
git -C "$repo" config core.editor true
for term in dumb xterm; do
  r=$(resolve "$work/empty-bin" "$term")
  [ -n "$r" ] || fail "a no-op core.editor should not hide git's compiled default (TERM=$term)"
  case "$r" in true|:|*/true) fail "a no-op core.editor should be discounted, got '$r' (TERM=$term)" ;; esac
done
git -C "$repo" config --unset core.editor
r=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.editor GIT_CONFIG_VALUE_0=true \
    resolve "$work/empty-bin" xterm)
[ -n "$r" ] || fail "a no-op core.editor from \`git -c\` should not hide git's compiled default"
ok "resolve: a no-op core.editor leaves the compiled default reachable"

git -C "$repo" config core.editor "my-editor --wait"
r=$(resolve "$codebin")
[ "$r" = "my-editor --wait" ] || fail "core.editor should win over both new rungs, got '$r'"
git -C "$repo" config --unset core.editor || true
ok "resolve: a configured editor wins over both"

# The iTerm2 host splits the session anchor was called from, so it exists only
# where that session can be named. TERM_PROGRAM says which terminal is running;
# ITERM_SESSION_ID is what the AppleScript matches a session on, and a review
# offered on the former alone dead-ends in "session not found".
cat > "$bin/host-editor.sh" <<EOF
#!/usr/bin/env bash
source "$here/../scripts/lib/review-editor.sh"
printf '%s' "\$(anchor_editor_host "\${1:-vi}")"
EOF
chmod +x "$bin/host-editor.sh"

host() {
  ( cd "$repo" && TMUX='' ANCHOR_EDITOR_LAUNCHER='' ANCHOR_HOST_RUNNER='' \
      TERM_PROGRAM="${2:-}" ITERM_SESSION_ID="$1" AGTERM_SESSION_ID='' \
      bash "$bin/host-editor.sh" vi </dev/null )
}

h=$(host '' iTerm.app)
[ "$h" != iterm2 ] || fail "an iTerm2 terminal with no session id cannot be split, got '$h'"
ok "host: the iTerm2 host needs the session id, not just the terminal name"

if [ "$(uname -s)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
  h=$(host 'w0t0p0:DEADBEEF-0000-0000-0000-000000000000')
  [ "$h" = iterm2 ] || fail "a named iTerm2 session should select the iterm2 host, got '$h'"
  ok "host: a named iTerm2 session selects the iterm2 host"
fi

# ====================== the host layer (DIFF-25a) ==========================
# A host is a place to draw a program, and which program does not change where it
# can be drawn — so the two modes are asked of one ranked set. These drive the
# dispatcher's selector directly: a launch would only show which host won.
cat > "$bin/host-mode.sh" <<EOF
#!/usr/bin/env bash
source "$here/../scripts/lib/review-host.sh"
printf '%s' "\$(anchor_review_host "\$1" "\${2:-}")"
EOF
chmod +x "$bin/host-mode.sh"

host_for() {
  ( cd "$repo" && PATH="$hostbin:$bin:/usr/bin:/bin" TMUX="${TMUX_ENV-}" \
      ANCHOR_HOST_RUNNER='' ITERM_SESSION_ID='' AGTERM_SESSION_ID='' \
      bash "$bin/host-mode.sh" "$@" </dev/null )
}

# Selection asks whether tmux is on PATH, never runs it, so a stub answers — and
# the case holds on a machine without tmux, which is where the asymmetry this
# layer removes would otherwise go unmeasured.
hostbin="$work/hostbin"; mkdir -p "$hostbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$hostbin/tmux"; chmod +x "$hostbin/tmux"

# The asymmetry this layer exists to remove: `diff` used to reach iTerm2 alone,
# so a review that could hand you a drafted document could not show you your own
# changeset. Inside tmux both modes answer the same.
TMUX_ENV='/tmp/fake-tmux,0,0'
[ "$(host_for edit vi)" = tmux ] || fail "edit should reach the tmux host"
[ "$(host_for diff)" = tmux ]    || fail "diff should reach the tmux host, as edit does"
unset TMUX_ENV
ok "host: both modes reach tmux, so neither reaches further than the other"

# `gui` is the one host that serves a single mode, and it says so itself rather
# than being kept out by a second selector: no editor window renders a changeset.
[ "$(host_for edit 'code --wait')" = gui ] || fail "a blocking editor should select the gui host"
[ "$(host_for diff 'code --wait')" != gui ] || fail "a viewer should never land in an editor's window"
ok "host: the gui window answers edit alone"

# What makes an editor a `gui` host is that it blocks, read off the command line
# from the flag each editor anchor knows needs. An editor anchor does not know
# is not guessed at: it goes looking for a terminal, and a `core.editor` is how
# it says otherwise (DIFF-16).
[ "$(host_for edit 'gvim -f')" = gui ]           || fail "gvim -f blocks, so it should select the gui host"
[ "$(host_for edit 'bbedit -W')" = gui ]         || fail "bbedit -W blocks, so it should select the gui host"
[ "$(host_for edit gvim)" != gui ]               || fail "gvim without -f does not block"
[ "$(host_for edit 'my-editor --hold')" != gui ] || fail "an unrecognized flag should not read as blocking"
ok "host: the wait flag each known editor needs is what selects the gui host"

# ====================== annotating instead of editing ======================
# Quitting the editor with exit code 3 hands the draft to the diff viewer, for a
# change the reviewer wants made rather than makes. The runner runs the command
# for real, and the stub revdiff keeps the draft it was shown and answers with
# $REVDIFF_STUB_OUTPUT.
cat > "$bin/run-host.sh" <<'EOF'
#!/usr/bin/env bash
sh -c "$1"
EOF
chmod +x "$bin/run-host.sh"
cat > "$viewerbin/revdiff" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "version: ${REVDIFF_STUB_VERSION:-v1.14.0}"; exit 0; }
[ "${1:-}" != --dump-keys ] || exit 0
for a in "$@"; do
  case "$a" in
    --output=*)      out="${a#--output=}" ;;
    "--only=(context).md") ;;
    --only=*)        cp "${a#--only=}" "$REVDIFF_NEW_CAPTURE" ;;
  esac
done
[ -z "${REVDIFF_STUB_OUTPUT:-}" ] || printf '%s\n' "$REVDIFF_STUB_OUTPUT" > "$out"
exit "${REVDIFF_STUB_RC:-0}"
EOF
chmod +x "$viewerbin/revdiff"
export ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" ANCHOR_HOST_RUNNER="$bin/run-host.sh"
export REVDIFF_NEW_CAPTURE="$work/annotated.md" EDITOR_BUFFER_CAPTURE="$work/buffer.txt"
# Helix gets the review's chords; the launcher stands in for it.
git -C "$repo" config anchor.edit.tool hx

o=$(EDITOR_STUB_MODE=replace EDITOR_STUB_TEXT='# Edited first' EDITOR_STUB_RC=3 \
    REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## proposed.md:1 (+)\nsay which gateway' \
    run --skill prepare-review --mode edit --files "$nothing" "$draft"); j=$(json_of "$o")
# shellcheck disable=SC2016
grep -q '│ `ZZ` approve' "$EDITOR_BUFFER_CAPTURE" || fail "the buffer should name the chord that approves: $(cat "$EDITOR_BUFFER_CAPTURE")"
# shellcheck disable=SC2016
grep -q '│ `ZQ` or `:cq` reject it (exit code 1)' "$EDITOR_BUFFER_CAPTURE" || fail "the buffer should name the chord and status that reject: $(cat "$EDITOR_BUFFER_CAPTURE")"
# shellcheck disable=SC2016
grep -q '│ `ZD` ask for changes in revdiff (saves, then exit code 3)' "$EDITOR_BUFFER_CAPTURE" || fail "the buffer should name the chord and status that switch: $(cat "$EDITOR_BUFFER_CAPTURE")"
grep -q 'hide hints' "$EDITOR_BUFFER_CAPTURE"    || fail "the buffer should say how to hide the keys: $(cat "$EDITOR_BUFFER_CAPTURE")"
[ "$(head -1 "$REVDIFF_NEW_CAPTURE")" = '# Edited first' ] || fail "the viewer should show the draft as saved: $(cat "$REVDIFF_NEW_CAPTURE")"
[ "$(verdict_of "$o")" = changes-requested ]       || fail "a note in the viewer -> changes-requested: $o"
[ "$(jq -r .mode <<<"$j")" = diff ]                || fail "the result is the viewer's: $j"
[ "$(jq '.comments|length' <<<"$j")" = 1 ]         || fail "the note comes back as a comment: $j"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = '# Edited first' ] || fail "the edit made before switching rides back: $j"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = description ] || fail "the edit is aimed at the artifact: $j"
untouched "a switch the viewer sent back with notes"
ok "annotate: exit 3 reopens the saved draft in the viewer, and its notes and the earlier edit both come back"

# The switch hands the verdict to the viewer, so an approval there is an
# approval of the draft as saved before the switch, and that is what the draft
# file holds afterwards.
d=$(draft_copy switched)
o=$(EDITOR_STUB_MODE=replace EDITOR_STUB_TEXT='# Edited first' EDITOR_STUB_RC=3 \
    REVDIFF_STUB_RC=10 REVDIFF_STUB_OUTPUT=$'## proposed.md:1 (+)\nlgtm' \
    run --skill prepare-review --mode edit --files "$nothing" "$d"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]                || fail "a lone lgtm in the viewer -> approved: $o"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = '# Edited first' ] || fail "the edit made before switching rides back: $j"
[ "$(cat "$d")" = '# Edited first' ]               || fail "the approved edit should reach the draft file: $(cat "$d")"
ok "annotate: an approval in the viewer writes the edit made before the switch over the draft file"

o=$(EDITOR_STUB_MODE=quit EDITOR_STUB_RC=3 REVDIFF_STUB_RC=0 REVDIFF_STUB_OUTPUT='' \
    run --skill prepare-review --mode edit --files "$nothing" "$draft" 2>/dev/null); j=$(json_of "$o")
cmp -s "$REVDIFF_NEW_CAPTURE" "$draft"             || fail "an unsaved switch shows the draft as drafted: $(cat "$REVDIFF_NEW_CAPTURE")"
untouched "a switch made without saving"
[ "$(jq -r .raw.exitCode <<<"$j")" = undecided ]   || fail "a viewer quit with no notes chooses no verdict: $o"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ]     || fail "nothing was edited: $j"
ok "annotate: switching without saving shows the draft as drafted"

git -C "$repo" config anchor.edit.hints false
EDITOR_STUB_MODE=save run --skill prepare-review --mode edit --files "$nothing" "$draft" >/dev/null
! grep -q 'ZQ\|ZD\|hide hints' "$EDITOR_BUFFER_CAPTURE" || fail "anchor.edit.hints=false drops the keys: $(cat "$EDITOR_BUFFER_CAPTURE")"
grep -q 'quit with exit code 3, and the' "$EDITOR_BUFFER_CAPTURE" \
  || fail "the switch itself stays when the keys are hidden: $(cat "$EDITOR_BUFFER_CAPTURE")"
git -C "$repo" config --unset anchor.edit.hints
ok "annotate: anchor.edit.hints=false drops the editor keys and keeps the switch"

git -C "$repo" config anchor.diff.tool bogus-viewer
EDITOR_STUB_MODE=save run --skill prepare-review --mode edit --files "$nothing" "$draft" >/dev/null 2>&1
# shellcheck disable=SC2016
grep -q '`ZD` ask for changes in revdiff' "$EDITOR_BUFFER_CAPTURE" || fail "the switch opens revdiff whatever anchor.diff.tool names: $(cat "$EDITOR_BUFFER_CAPTURE")"
git -C "$repo" config --unset anchor.diff.tool
git -C "$repo" config --unset anchor.edit.tool
ok "annotate: the switch names revdiff whatever anchor.diff.tool names"

# --- the real Vim and Neovim, driven headless through their chords -----------
# The runner types $VIM_KEYS in normal mode after the maps load, so the chord
# runs through the map edit.sh passes, not through the editor's built-in key.
cat > "$bin/vim-keys.sh" <<'EOF'
#!/usr/bin/env bash
sh -c "$1 -c 'normal $VIM_KEYS'" </dev/null >/dev/null 2>&1
EOF
chmod +x "$bin/vim-keys.sh"
for vimbin in vim nvim; do
  if ! command -v "$vimbin" >/dev/null 2>&1; then
    echo "ok - # SKIP $vimbin chords: $vimbin not installed"
    continue
  fi
  vimed="$vimbin -u NONE -i NONE -N -n -es"
  o=$(VIM_KEYS=ZZ GIT_EDITOR="$vimed" ANCHOR_EDITOR_LAUNCHER='' ANCHOR_HOST_RUNNER="$bin/vim-keys.sh" \
      run --skill prepare-review --mode edit --files "$nothing" "$draft" 2>&1); j=$(json_of "$o")
  [ "$(verdict_of "$o")" = approved ]            || fail "$vimbin: ZZ on an unchanged draft approves it: $o"
  [ "$(jq '.editedFields|length' <<<"$j")" = 0 ] || fail "$vimbin: ZZ unchanged edits nothing: $j"
  untouched "$vimbin: ZZ on an unchanged draft"
  o=$(VIM_KEYS=ZQ GIT_EDITOR="$vimed" ANCHOR_EDITOR_LAUNCHER='' ANCHOR_HOST_RUNNER="$bin/vim-keys.sh" \
      run --skill prepare-review --mode edit --files "$nothing" "$draft" 2>&1)
  [ "$(verdict_of "$o")" = rejected ]            || fail "$vimbin: ZQ rejects: $o"
  untouched "$vimbin: ZQ"
  ok "$vimbin: ZZ approves a draft left unchanged, ZQ rejects it, and neither changes the draft file"
done

echo "# all checks passed"
