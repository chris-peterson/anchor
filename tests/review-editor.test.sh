#!/usr/bin/env bash
# Functional test for the editor review backend (scripts/review/editor.sh) and
# the per-skill backend key the dispatcher resolves for it.
#
# Drives the real dispatcher with ANCHOR_EDITOR_LAUNCHER pointed at a stub that
# stands in for the user's editor: it rewrites, empties, or leaves the buffer
# alone, and can exit non-zero the way `:cq` does. Asserts the normalized DIFF
# contract the adapter emits, and that what the editor saved comes back as the
# artifact. Requires jq.
set -euo pipefail

# Hermetic: ignore the user's global/system git config so backend selection is
# controlled per-case here, not by a global anchor.reviewBackend.
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

# --- stub editor: the seam ANCHOR_EDITOR_LAUNCHER opens. It receives the buffer
# path, copies it aside so a case can assert what the user would have seen, and
# then acts out one of the four things a user does with an editor.
#   EDITOR_STUB_MODE=keep    save without changing anything (the default)
#   EDITOR_STUB_MODE=replace write $EDITOR_STUB_TEXT as the whole artifact
#   EDITOR_STUB_MODE=empty   leave an empty buffer
#   EDITOR_STUB_MODE=fail    exit $EDITOR_STUB_RC without saving (vim's `:cq`)
cat > "$bin/stub-editor.sh" <<'EOF'
#!/usr/bin/env bash
buffer="$1"
[ -n "${EDITOR_BUFFER_CAPTURE:-}" ] && cp "$buffer" "$EDITOR_BUFFER_CAPTURE"
case "${EDITOR_STUB_MODE:-keep}" in
  replace)
    scissors='------------------------ >8 ------------------------'
    rest=$(sed -n "/^${scissors}\$/,\$p" "$buffer")
    { printf '%s\n\n' "${EDITOR_STUB_TEXT:-}"; printf '%s\n' "$rest"; } > "$buffer"
    ;;
  empty) : > "$buffer" ;;
  fail)  exit "${EDITOR_STUB_RC:-1}" ;;
esac
exit 0
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

# Hermetic in PATH as well as in git config. Backend resolution settles the
# configured name against what is installed, so without a fixed PATH the
# assertions would read the host's installed set rather than the key resolution
# they are about. A stub revdiff ahead of everything makes the configured
# backend present, which is the state the substitution rule leaves alone. It
# sits in its own dir, not
# $bin: the probe cases below run against $bin precisely to assert what happens
# when no viewer is installed.
viewerbin="$work/viewerbin"; mkdir -p "$viewerbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$viewerbin/revdiff"; chmod +x "$viewerbin/revdiff"
run() { ( cd "$repo" && PATH="$viewerbin:$PATH" bash "$dispatch" "$@" ); }
verdict_of() { sed -n 's/^REVIEW_VERDICT=//p' <<<"$1"; }
json_of()    { sed -n 's/^REVIEW_OUTPUT=//p' <<<"$1"; }

git -C "$repo" config anchor.reviewBackend editor

# The proposed artifact of a two-path review — markdown, because three of the
# four artifacts anchor drafts are, and `#` must survive as a heading.
draft="$work/proposed.md"
printf '# Why this change\n\nThe reviewer needs the why first.\n' > "$draft"
prior="$work/prior.md"
printf '# Why this change\n\nStale text.\n' > "$prior"

# --- saved unchanged -> approved, nothing edited ----------------------------
export EDITOR_STUB_MODE=keep
export EDITOR_BUFFER_CAPTURE="$work/buffer.txt"
o=$(run --skill prepare-review --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ]                  || fail "unchanged -> $(verdict_of "$o"), want approved"
[ "$(jq -r .backend <<<"$j")" = editor ]             || fail "backend should be editor"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ]       || fail "unchanged should edit nothing"
[ "$(jq '.comments|length' <<<"$j")" = 0 ]           || fail "editor backend carries no comments"
[ "$(jq -r .capabilities.editableDescription <<<"$j")" = true ] || fail "caps.editableDescription"
[ "$(jq -r .reviewCompleteness <<<"$j")" = null ]    || fail "completeness should be null"
ok "editor: saved unchanged -> approved, no editedFields"

# The buffer is the artifact, then the scissors, then the change under review.
grep -qx '# Why this change' "$EDITOR_BUFFER_CAPTURE" || fail "markdown heading missing from buffer"
grep -q '>8' "$EDITOR_BUFFER_CAPTURE"                 || fail "scissors line missing from buffer"
grep -q 'Stale text' "$EDITOR_BUFFER_CAPTURE"         || fail "the diff against the prior file is not below the scissors"
ok "editor: buffer is artifact + scissors + the change under review"

# --- saved changed -> the saved text IS the artifact ------------------------
export EDITOR_STUB_MODE=replace
export EDITOR_STUB_TEXT='# Rewritten by hand

## A heading the editor added'
o=$(run --skill prepare-review --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "changed -> $(verdict_of "$o"), want approved"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = description ] || fail "target should be description"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] \
  || fail "edited text not adopted verbatim: $(jq -c '.editedFields[0].edited' <<<"$j")"
[ "$(jq -r '.editedFields[0].original' <<<"$j")" = "$(cat "$draft")" ] || fail "original not carried"
[[ "$(jq -r '.editedFields[0].edited' <<<"$j")" != *'>8'* ]] || fail "context leaked past the scissors"
ok "editor: saved changed -> approved, edited text adopted verbatim (markdown intact)"

# --- emptied -> abort -------------------------------------------------------
export EDITOR_STUB_MODE=empty
o=$(run --skill prepare-review --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "emptied -> $(verdict_of "$o"), want no-verdict"
[ "$(jq '.editedFields|length' <<<"$j")" = 0 ] || fail "an abort edits nothing"
ok "editor: emptied buffer -> no-verdict (abort)"

# --- exited without saving -> abort ----------------------------------------
export EDITOR_STUB_MODE=fail EDITOR_STUB_RC=3
o=$(run --skill prepare-review --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ]    || fail "editor failure -> want no-verdict"
[ "$(jq -r .raw.exitCode <<<"$j")" = 3 ] || fail "raw.exitCode should carry the editor's status"
ok "editor: non-zero editor exit -> no-verdict, status in raw.exitCode"
unset EDITOR_STUB_RC

# --- a drafted commit message rides the same path --------------------------
export EDITOR_STUB_MODE=replace
export EDITOR_STUB_TEXT='Rewrite the subject

And the body the user typed.'
msg="$work/msg.txt"; printf 'Add a feature\n\nThe body explains why.\n' > "$msg"
printf 'one\ntwo\nthree\n' > "$repo/a.txt"
o=$(run --skill commit --local --message-file "$msg"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = approved ] || fail "message edit -> $(verdict_of "$o")"
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = commit-message ] || fail "target should be commit-message"
[ "$(jq -r '.editedFields[0].edited' <<<"$j")" = "$EDITOR_STUB_TEXT" ] || fail "edited message not adopted"
grep -q 'three' "$EDITOR_BUFFER_CAPTURE" || fail "staged diff should sit below the scissors"
ok "editor: --message-file -> editedFields[commit-message], diff below the scissors"

# The seeded message is the editable region, so it is not repeated as a header row.
[ "$(grep -c 'The body explains why' "$EDITOR_BUFFER_CAPTURE")" = 1 ] \
  || fail "the message body appears twice in the buffer"
ok "editor: the seeded message body is not duplicated in the header"

# --- the artifact target follows the invoking skill ------------------------
export EDITOR_STUB_MODE=replace EDITOR_STUB_TEXT='## Issue body'
o=$(run --skill issue --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = issue-body ] || fail "issue -> issue-body"
o=$(run --skill release --files "$prior" "$draft"); j=$(json_of "$o")
[ "$(jq -r '.editedFields[0].target' <<<"$j")" = release-notes ] || fail "release -> release-notes"
ok "editor: editedFields target follows --skill"

# --- a diff with no drafted artifact has nothing to edit -------------------
export EDITOR_STUB_MODE=keep
o=$(run --skill commit --previous 2>"$work/err.txt"); j=$(json_of "$o")
[ "$(verdict_of "$o")" = no-verdict ] || fail "diff-only review -> want no-verdict"
grep -q 'reviewBackend' "$work/err.txt" || fail "the cause should name the key that fixes it"
ok "editor: a diff-only review -> no-verdict, cause on stderr"

# ====================== per-skill backend selection ========================
unset ANCHOR_EDITOR_LAUNCHER
export EDITOR_STUB_MODE=keep

# A stub split runner, so a revdiff review resolves without opening a pane.
cat > "$bin/stub-split-runner.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/stub-split-runner.sh"
export ANCHOR_SPLIT_RUNNER="$bin/stub-split-runner.sh"

backend_of() { jq -r .backend <<<"$(json_of "$1")"; }

git -C "$repo" config anchor.reviewBackend revdiff
git -C "$repo" config anchor.commit.reviewBackend editor
[ "$(backend_of "$(run --skill commit --previous 2>/dev/null)")" = editor ] \
  || fail "anchor.commit.reviewBackend should override the umbrella key"
[ "$(backend_of "$(run --skill prepare-review --previous)")" = revdiff ] \
  || fail "a skill with no key of its own should keep the umbrella value"
[ "$(backend_of "$(run --previous)")" = revdiff ] \
  || fail "no --skill should resolve the umbrella key"
ok "backend: anchor.<skill>.reviewBackend overrides, others keep the umbrella key"

# And in the other direction — a per-skill key wins over an umbrella `editor`.
git -C "$repo" config anchor.reviewBackend editor
git -C "$repo" config anchor.commit.reviewBackend revdiff
[ "$(backend_of "$(run --skill commit --previous)")" = revdiff ] \
  || fail "per-skill key should win over an umbrella editor too"
ok "backend: the per-skill key wins in both directions"

# --- an unknown per-skill backend fails the way an unknown umbrella one does
git -C "$repo" config anchor.commit.reviewBackend bogus
if run --skill commit --previous 2>/dev/null; then fail "unknown per-skill backend should exit non-zero"; fi
ok "backend: an unknown per-skill backend exits non-zero"

# ====================== --print-backend probe ==============================
# The skills ask which backend they got before deciding whether a visual review
# is available at all, so the resolution lives here rather than in skill prose.
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

git -C "$repo" config anchor.reviewBackend editor
git -C "$repo" config --unset anchor.commit.reviewBackend
o=$(probe --skill commit --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" = editor ]        || fail "--print-backend name"
[ "$(key_of REVIEW_BACKEND_AVAILABLE "$o")" = 0 ]   || fail "a selected editor backend with no editor to open is not available"
[ "$(key_of REVIEW_EDITOR_AVAILABLE "$o")" = 0 ]    || fail "no editor resolves, so the editor rung is not offerable"
ok "probe: a selected editor backend reports unavailable with nowhere to open one"

# The editor axis is reported on every probe, not only when editor is selected:
# it is what a skill offers as the rung below a viewer that is missing or died.
o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" \
     bash "$dispatch" --skill commit --print-backend )
[ "$(key_of REVIEW_BACKEND_AVAILABLE "$o")" = 1 ] || fail "a reachable editor makes the selected editor backend available"
[ "$(key_of REVIEW_EDITOR_AVAILABLE "$o")" = 1 ]  || fail "a reachable editor should be reported as offerable"
ok "probe: a reachable editor is reported on its own axis"

git -C "$repo" config anchor.commit.reviewBackend definitely-not-installed
o=$(probe --skill commit --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" = definitely-not-installed ] || fail "probe should report the per-skill key"
[ "$(key_of REVIEW_BACKEND_AVAILABLE "$o")" = 0 ]              || fail "an absent binary should report unavailable"
ok "probe: with no diff viewer installed at all, the probe reports unavailable"

# With one installed, the probe coalesces onto it and names what config wanted.
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/revdiff"
o=$(probe --skill commit --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" = revdiff ]                               || fail "probe should coalesce onto the installed tool"
[ "$(key_of REVIEW_BACKEND_AVAILABLE "$o")" = 1 ]                           || fail "a coalesced backend is available"
[ "$(key_of REVIEW_BACKEND_CONFIGURED "$o")" = definitely-not-installed ]   || fail "the substitution should name what config asked for"
ok "probe: coalesces onto an installed tool and names the configured one"

# ...but never onto the editor: it edits one artifact rather than showing a diff.
rm -f "$bin/revdiff"
git -C "$repo" config --unset anchor.reviewBackend
o=$(probe --skill commit --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" != editor ] || fail "editor should never be substituted automatically"
ok "probe: an absent diff viewer never coalesces onto the editor"

# --backend drives the review directly, config keys ignored.
git -C "$repo" config anchor.reviewBackend revdiff
git -C "$repo" config anchor.commit.reviewBackend revdiff
export ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" EDITOR_STUB_MODE=keep
o=$(run --skill commit --backend editor --files "$prior" "$draft")
[ "$(jq -r .backend <<<"$(json_of "$o")")" = editor ] || fail "--backend should override both config keys"
o=$(run --skill commit --backend editor --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" = editor ] || fail "--backend should drive the probe too"
unset ANCHOR_EDITOR_LAUNCHER
ok "backend: --backend overrides the config keys, for the probe and the launch"

# The probe reports; it never opens anything.
export EDITOR_BUFFER_CAPTURE="$work/never.txt"
rm -f "$EDITOR_BUFFER_CAPTURE"
probe --skill commit --print-backend >/dev/null
[ ! -f "$EDITOR_BUFFER_CAPTURE" ] || fail "--print-backend should launch nothing"
ok "probe: --print-backend launches nothing"
unset EDITOR_BUFFER_CAPTURE

# ====================== per-skill defaults (CONFIG-15) =====================
# With nothing configured, the default follows what the review is about.
git -C "$repo" config --unset anchor.reviewBackend
git -C "$repo" config --unset anchor.commit.reviewBackend
cat > "$bin/revdiff" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/revdiff"

for skill in prepare-review issue release; do
  o=$( cd "$repo" && PATH="$bin:/usr/bin:/bin" ANCHOR_EDITOR_LAUNCHER="$bin/stub-editor.sh" \
       bash "$dispatch" --skill "$skill" --print-backend )
  [ "$(key_of REVIEW_BACKEND "$o")" = editor ] || fail "$skill reviews one drafted document, so it should default to the editor"
done
ok "default: a drafted-document skill opens the editor with nothing configured"

for skill in commit review; do
  o=$(probe --skill "$skill" --print-backend)
  [ "$(key_of REVIEW_BACKEND "$o")" = revdiff ] || fail "$skill reviews a changeset, so it should default to the viewer"
done
ok "default: a changeset skill opens the diff viewer with nothing configured"

# A *defaulted* editor with nowhere to open gives way to an installed viewer, and
# the probe names what it stepped aside from: nobody asked for the editor, and
# dead-ending the flow in a host problem is worse than showing the diff (DIFF-11).
o=$(probe --skill prepare-review --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" = revdiff ]           || fail "an unreachable defaulted editor should give way to an installed viewer"
[ "$(key_of REVIEW_BACKEND_AVAILABLE "$o")" = 1 ]       || fail "the viewer that stood in is available"
[ "$(key_of REVIEW_BACKEND_CONFIGURED "$o")" = editor ] || fail "the substitution should name the editor it replaced"
ok "default: an unreachable defaulted editor gives way to an installed viewer"

# A *configured* one is kept and reports the missing piece itself.
git -C "$repo" config anchor.prepare-review.reviewBackend editor
o=$(probe --skill prepare-review --print-backend)
[ "$(key_of REVIEW_BACKEND "$o")" = editor ]      || fail "a configured editor should be kept, not swapped for a viewer"
[ "$(key_of REVIEW_BACKEND_AVAILABLE "$o")" = 0 ] || fail "kept, and reported unavailable"
git -C "$repo" config --unset anchor.prepare-review.reviewBackend
ok "default: a configured editor is kept even with nowhere to open it"

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
# there.
resolve() { ( cd "$repo" && PATH="$1:/usr/bin:/bin" TERM="${2-dumb}" GIT_EDITOR=true bash "$bin/resolve-editor.sh" ); }

r=$(resolve "$codebin")
[ "$r" = "code --wait" ] || fail "a blocking VS Code on PATH should be reached, got '$r'"
ok "resolve: past git's chain, a blocking VS Code on PATH"

# A dumb terminal is git's answer about the stdio git itself was handed. This
# backend puts the editor in a terminal the host opens (DIFF-17), which is a
# separate question, so the rung stands either way.
for term in dumb xterm; do
  r=$(resolve "$work/empty-bin" "$term")
  [ -n "$r" ] || fail "git's own compiled default should still resolve (TERM=$term)"
  case "$r" in true|:|*/true) fail "a no-op compiled default should be discounted (TERM=$term)" ;; esac
done
ok "resolve: and below that, git's own compiled default, dumb terminal or not"

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
git -C "$repo" config --unset core.editor
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
