#!/usr/bin/env bash
# Functional test for `edit` mode (scripts/review/edit.sh) and the two axes the
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
    rest=$(sed -n "/^${scissors}\$/,\$p" "$buffer")
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

# Hermetic in PATH as well as in git config. Tool resolution settles the
# configured name against what is installed, so without a fixed PATH the
# assertions would read the host's installed set rather than the key resolution
# they are about. A stub revdiff ahead of everything makes the configured
# tool present, which is the state the substitution rule leaves alone. It
# sits in its own dir, not
# $bin: the probe cases below run against $bin precisely to assert what happens
# when no viewer is installed.
viewerbin="$work/viewerbin"; mkdir -p "$viewerbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$viewerbin/revdiff"; chmod +x "$viewerbin/revdiff"
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

# --- saved unchanged -> approved, nothing edited ----------------------------
export EDITOR_STUB_MODE=save
export EDITOR_BUFFER_CAPTURE="$work/buffer.txt"
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]                  || fail "unchanged -> $(verdict_of "$o"), want approved"
[ "$(jq -r .mode <<<"$j")" = edit ]                  || fail "mode should be edit"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ]       || fail "unchanged should edit nothing"
[ "$(jq '.comments|length' <<<"$j")" = 0 ]           || fail "edit mode carries no comments"
[ "$(jq -r .capabilities.editableDescription <<<"$j")" = true ] || fail "caps.editableDescription"
[ "$(jq -r .reviewCompleteness <<<"$j")" = null ]    || fail "completeness should be null"
ok "edit: saved unchanged -> approved, no editedFields"

# The buffer is the artifact, then the scissors, then the change under review.
grep -qx '# Why this change' "$EDITOR_BUFFER_CAPTURE" || fail "markdown heading missing from buffer"
grep -q '>8' "$EDITOR_BUFFER_CAPTURE"                 || fail "scissors line missing from buffer"
grep -q 'Stale text' "$EDITOR_BUFFER_CAPTURE"         || fail "the diff against the prior file is not below the scissors"
ok "edit: buffer is artifact + scissors + the change under review"

# The editor reads the name to pick its mode, so a markdown artifact opens under
# a `.md` buffer and markdown preview is a keystroke away.
[[ "$(cat "$EDITOR_BUFFER_CAPTURE.path")" == *.md ]] \
  || fail "a markdown artifact should open in a .md buffer, got $(cat "$EDITOR_BUFFER_CAPTURE.path")"
ok "edit: a markdown artifact opens in a .md buffer"

# --- saved changed -> the saved text IS the artifact ------------------------
export EDITOR_STUB_MODE=replace
export EDITOR_STUB_TEXT='# Rewritten by hand

## A heading the editor added'
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "changed -> $(verdict_of "$o"), want approved"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = description ] || fail "target should be description"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] \
  || fail "edited text not adopted verbatim: $(jq -c '.editedFields[0].edited' <<<"$j")"
[ "$(jq -r '.editedFields[0].original' <<<"$j")" = "$(cat "$draft")" ] || fail "original not carried"
[[ "$(jq -r '.editedFields[0].edited' <<<"$j")" != *'>8'* ]] || fail "context leaked past the scissors"
ok "edit: saved changed -> approved, edited text adopted verbatim (markdown intact)"

# --- emptied -> abort -------------------------------------------------------
export EDITOR_STUB_MODE=empty
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "emptied -> $(verdict_of "$o"), want no-verdict"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ] || fail "an abort edits nothing"
ok "edit: emptied buffer -> no-verdict (abort)"

# --- quit without saving -> abort, and the save is what would have approved --
export EDITOR_STUB_MODE=quit
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft" 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]             || fail "quit unsaved -> $(verdict_of "$o"), want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = unsaved ]    || fail "raw.exitCode should be unsaved, got $(jq -c .raw <<<"$j")"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ]    || fail "an abort edits nothing"
grep -q 'without saving' "$work/err.txt"          || fail "the remedy should reach stderr"
ok "edit: quit without saving -> no-verdict (abort), cause unsaved"

# --- exited non-zero -> abort ----------------------------------------------
export EDITOR_STUB_MODE=quit EDITOR_STUB_RC=3
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]    || fail "editor failure -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = 3 ] || fail "raw.exitCode should carry the editor's status"
ok "edit: non-zero editor exit -> no-verdict, status in raw.exitCode"
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
ok "edit: a closed review pane -> no-verdict, cause named rather than numbered"

# But the pane closing after a save is not that case: the reviewer answered and
# the answer is on disk, so it is graded like any other save rather than thrown
# away with the terminal that was drawing it.
export EDITOR_STUB_MODE=replace EDITOR_STUB_RC=124
export EDITOR_STUB_TEXT='# Saved, then the pane went away'
o=$(run --skill prepare-review --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "saved then pane closed -> $(verdict_of "$o"), want approved"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] \
  || fail "the saved text should survive the pane, got $(jq -c '.editedFields[0].edited' <<<"$j")"
ok "edit: saved, then the pane closed -> approved, the saved text survives"
unset EDITOR_STUB_RC EDITOR_STUB_TEXT
export EDITOR_STUB_MODE=save

# And with no host at all, the editor was never asked — a third cause, kept
# apart from the two above so none of them is reported as the others. PATH is
# pinned to the stubs: inherit the developer's and the ladder finds their real
# VS Code, whose `gui` host needs no terminal — the case then launches an editor
# for real and waits for someone to close it.
o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER='' TMUX='' \
     ITERM_SESSION_ID='' ANCHOR_SPLIT_RUNNER='' GIT_EDITOR=true \
     bash "$dispatch" --skill prepare-review --mode edit \
     --files "$prior" "$draft" </dev/null 2>/dev/null ); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]            || fail "nowhere to open -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = no-host ]   || fail "raw.exitCode should be no-host, got $(jq -c .raw <<<"$j")"
ok "edit: nowhere to open the editor -> no-verdict, no-host"

# --- a drafted commit message rides the same path --------------------------
export EDITOR_STUB_MODE=replace
export EDITOR_STUB_TEXT='Rewrite the subject

And the body the user typed.'
msg="$work/msg.txt"; printf 'Add a feature\n\nThe body explains why.\n' > "$msg"
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
o=$(run --skill commit --mode edit --local --message-file "$msg"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "message edit -> $(verdict_of "$o")"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = commit-message ] || fail "target should be commit-message"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] || fail "edited message not adopted"
grep -q 'three' "$EDITOR_BUFFER_CAPTURE" || fail "staged diff should sit below the scissors"
ok "edit: --message-file -> editedFields[commit-message], diff below the scissors"

[[ "$(cat "$EDITOR_BUFFER_CAPTURE.path")" == *.txt ]] \
  || fail "a commit message should open in a .txt buffer, got $(cat "$EDITOR_BUFFER_CAPTURE.path")"
ok "edit: a commit message opens in a .txt buffer"

# The seeded message is the editable region, so it is not repeated as a header row.
[ "$(grep -c 'The body explains why' "$EDITOR_BUFFER_CAPTURE")" = 1 ] \
  || fail "the message body appears twice in the buffer"
ok "edit: the seeded message body is not duplicated in the header"

# --- the artifact target follows the invoking skill ------------------------
export EDITOR_STUB_MODE=replace EDITOR_STUB_TEXT='## Issue body'
o=$(run --skill issue --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = issue-body ] || fail "issue -> issue-body"
o=$(run --skill release --mode edit --files "$prior" "$draft"); j=$(json_of "$o")
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
cat > "$bin/stub-split-runner.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/stub-split-runner.sh"
export ANCHOR_SPLIT_RUNNER="$bin/stub-split-runner.sh"

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

# anchor.edit.tool is the mirror of anchor.diff.tool — edit mode's tool
# half, above git's chain because it is the narrower statement.
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

# --- an unknown diff tool fails on its own axis, once there is nothing to
# coalesce onto. With a viewer installed it never reaches the adapter check:
# the within-mode substitution takes it to the installed one first.
git -C "$repo" config anchor.diff.tool bogus-viewer
v=$( ( cd "$repo" && PATH="$bin:/usr/bin:/bin" bash "$dispatch" --skill commit --previous ) 2>/dev/null )
[ "$(verdict_of "$v")" = no-verdict ] \
  || fail "an unknown diff tool with nothing installed should report no-verdict"
[ "$(jq -r .raw.exitCode <<<"$(json_of "$v")")" = unknown-tool ] \
  || fail "the cause should name it as a tool anchor has no adapter for"
[ "$(tool_of "$(run --skill commit --previous)")" = revdiff ] \
  || fail "with a viewer installed, an unknown one should coalesce onto it"
git -C "$repo" config --unset anchor.diff.tool || true
ok "tool: an unknown diff tool reports no-verdict, or coalesces where it can"

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
      ITERM_SESSION_ID='' ANCHOR_SPLIT_RUNNER='' \
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
ok "probe: a reachable editor is reported on its own axis"

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

git -C "$repo" config anchor.diff.tool definitely-not-installed
o=$(probe --skill commit --probe)
[ "$(key_of REVIEW_TOOL "$o")" = definitely-not-installed ] || fail "probe should report the configured viewer"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 0 ]                      || fail "an absent binary should report unavailable"
ok "probe: with no diff viewer installed at all, the probe reports unavailable"

# With one installed, the probe coalesces onto it and names what config wanted.
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/revdiff"
o=$(probe --skill commit --probe)
[ "$(key_of REVIEW_TOOL "$o")" = revdiff ]                               || fail "probe should coalesce onto the installed tool"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 1 ]                                   || fail "a coalesced tool is available"
[ "$(key_of REVIEW_TOOL_CONFIGURED "$o")" = definitely-not-installed ]   || fail "the substitution should name what config asked for"
ok "probe: coalesces onto an installed tool and names the configured one"

# ...but never out of the mode: coalescing picks another viewer, never the
# editor, which edits one artifact rather than showing a diff.
rm -f "$bin/revdiff"
git -C "$repo" config --unset anchor.diff.tool || true
o=$(probe --skill commit --probe)
[ "$(key_of REVIEW_MODE "$o")" = diff ] || fail "an absent viewer should never flip the mode to edit"
ok "probe: an absent diff viewer never coalesces into edit mode"

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
grep -q 'anchor.edit.tool' "$work/legacy.txt"   || fail "the keys that replaced it should be named on stderr"
grep -q 'anchor.diff.tool' "$work/legacy.txt"   || fail "the keys that replaced it should be named on stderr"
git -C "$repo" config --unset anchor.reviewBackend || true
ok "mode: the superseded anchor.reviewBackend key does nothing, and says so"
unset EDITOR_BUFFER_CAPTURE

# ====================== the subject-picked mode (CONFIG-15) ================
# The mode follows what the review is about, and there is no key that says
# otherwise — only whether the shape it picked can actually open.
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
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

# A *defaulted* editor with nowhere to open gives way to an installed viewer, and
# the probe names what it stepped aside from: nobody asked for the editor, and
# dead-ending the flow in a host problem is worse than showing the diff (DIFF-11).
o=$(probe --skill prepare-review --probe --files "$nothing" "$draft")
[ "$(key_of REVIEW_MODE "$o")" = diff ]              || fail "an unreachable subject-picked edit mode should give way to an installed viewer"
[ "$(key_of REVIEW_AVAILABLE "$o")" = 1 ]            || fail "the viewer that stood in is available"
[ "$(key_of REVIEW_MODE_CONFIGURED "$o")" = edit ]   || fail "the substitution should name the mode it replaced"
ok "default: an unreachable defaulted editor gives way to an installed viewer"

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
      TMUX='' ANCHOR_EDITOR_LAUNCHER='' ITERM_SESSION_ID='' \
      ANCHOR_SPLIT_RUNNER="${3-}" bash "$bin/resolve-editor.sh" </dev/null )
}

# With a terminal to host, the editor a plain `git commit` opens wins over a
# GUI editor anchor merely found: it renders in the pane anchor labels and
# focuses, where VS Code opens a window behind the terminal.
r=$(resolve "$codebin" dumb "$bin/stub-split-runner.sh")
[ -n "$r" ] || fail "git's compiled default should resolve with a terminal host"
[ "$r" != "code --wait" ] || fail "a hostable terminal should outrank the GUI rung, got '$r'"
case "$r" in true|:|*/true) fail "a no-op compiled default should be discounted" ;; esac
ok "resolve: with a terminal host, git's own compiled default"

# And with nowhere to put a terminal, the GUI rung is the only one that reaches
# anything at all.
r=$(resolve "$codebin")
[ "$r" = "code --wait" ] || fail "with no terminal host, a blocking VS Code should be reached, got '$r'"
ok "resolve: with nowhere to host one, a blocking VS Code on PATH"

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
  ( cd "$repo" && TMUX='' ANCHOR_EDITOR_LAUNCHER='' ANCHOR_SPLIT_RUNNER='' \
      TERM_PROGRAM="${2:-}" ITERM_SESSION_ID="$1" \
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

echo "# all checks passed"
