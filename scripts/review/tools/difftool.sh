#!/usr/bin/env bash
# git's own difftool — a `diff` mode tool, and the one that answers for every
# tool the user already configured for `git difftool`. Sourced by ../diff.sh;
# the contract these functions answer to is documented at the top of that file.
#
# What makes a difftool gradeable is that the reviewer can *write* through it.
# `--dir-diff` symlinks the working-tree side, and `--no-index` is handed the
# real paths, so an edit made in the tool lands in the file. That edit is the
# review: a fix typed straight into the code, a question left in whatever comment
# syntax the file already uses, a `TODO:` marking something to come back to.
# There is no marker convention to learn and nothing to strip — anchor compares
# the files against the snapshot it took before launching and hands the skill the
# diff of what the reviewer wrote, to read as feedback.
#
# So this tool is a `changes-requested` machine: a tool the reviewer wrote
# through returns their edits, and one they only read returns the clean quit that
# every difftool already uses to mean "nothing to say".
#
# The tool's own exit status is deliberately not consulted: `git difftool` drops
# it without --trust-exit-code, and plenty of tools use non-zero to mean "the
# files differ". A non-zero here is git difftool's own failure — an unlaunchable
# tool — which is a review that never happened rather than a verdict.

# A difftool sees a changeset and reports no per-hunk state, and the edits it
# returns are the reviewer's own text rather than a round-trip of anchor's draft.
# shellcheck disable=SC2034
diff_tool_caps='{"producesVerdict":true,"perHunkReview":false,"editableCommitMessage":false,"editableDescription":false,"sideMarkers":false}'
diff_tool_install_hint='set diff.tool, or difftool.<name>.cmd, to a tool git can launch'

# Where the pre-launch snapshot lives, and the paths it covers.
difftool_snapshot=""
difftool_paths=()

# The tool is git's to find, not PATH's — the same question the dispatcher asks
# when it resolves the tool and reports whether it can open.
diff_tool_available() { anchor_difftool_known "$1"; }

# The files this review puts in front of the reviewer, as working-tree paths. A
# `--files` review edits the proposed side; the left is a baseline copied aside.
# shellcheck disable=SC2154
difftool_reviewed_paths() {
  if [[ "$review_subject" == "files" ]]; then
    printf '%s\n' "$files_right"
  else
    git diff --name-only "$diff_range" 2>/dev/null || true
  fi
}

# Snapshot every reviewed file before the tool opens, so what the reviewer wrote
# can be told apart from what was already there. Copies rather than hashes: the
# comparison has to produce the *diff* of their edits, not just the fact of one.
diff_tool_before() {
  local path
  difftool_snapshot=$(mktemp -d "${TMPDIR:-/tmp}/anchor-review-snap.XXXXXX")
  difftool_paths=()
  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] || continue
    mkdir -p "$difftool_snapshot/$(dirname "$path")"
    cp "$path" "$difftool_snapshot/$path"
    difftool_paths+=("$path")
  done < <(difftool_reviewed_paths)
}

# shellcheck disable=SC2154
diff_tool_command() {
  # The header the mode adapter seeded goes unused: a difftool shows two file
  # trees and has nowhere to put a third thing. The manifest the skill prints
  # before launching is what carries that context here.
  local bin="$1" out_file="$2" err_file="$3"
  local cmd
  cmd="git difftool --no-prompt --tool=$(anchor_split_sq "$review_tool")"
  if [[ "$review_subject" == "files" ]]; then
    cmd="$cmd --no-index -- $(anchor_split_sq "$files_left") $(anchor_split_sq "$files_right")"
  else
    # --dir-diff opens the whole changeset once instead of prompting file by
    # file, and symlinks the working-tree side so an edit reaches the real file.
    cmd="$cmd --dir-diff $(anchor_split_sq "$diff_range")"
  fi
  cmd="$cmd >$(anchor_split_sq "$out_file") 2>$(anchor_split_sq "$err_file")"
  printf '%s' "$cmd"
}

# The reviewer's edits, one comment per file they wrote in, carrying the diff of
# what they wrote. Anchored to the file rather than a line: an edit is as likely
# to be a fix spanning hunks as a question on one line, and handing the skill the
# whole change lets it read which it is.
#
# The out_file is ignored — a difftool reports through the tree, not stdout.
diff_tool_comments() {
  local path body first=1
  printf '['
  for path in ${difftool_paths[@]+"${difftool_paths[@]}"}; do
    [[ -f "$path" ]] || continue
    body=$(diff -u "$difftool_snapshot/$path" "$path" 2>/dev/null || true)
    [[ -n "$body" ]] || continue
    # The temp path in the ---/+++ header names anchor's snapshot, which is
    # noise to a reader; the file is already named by the comment.
    body=$(printf '%s' "$body" | sed '1,2d')
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    jq -cn --arg f "$path" --arg b "$body" \
      '{body:("The reviewer edited this file:\n\n```diff\n" + $b + "\n```"),
        target:"file", file:$f, startLine:null, endLine:null, side:"new", raw:$b}'
  done
  printf ']'
}

# A difftool's answer is what it wrote. Edits mean there is something to act on,
# so the flow goes back through the skill to read them; no edits and a clean exit
# is the quit every difftool already uses to mean nothing to say.
diff_tool_verdict() {
  local rc="$1" comments="$2"
  if [[ "$rc" -ne 0 ]]; then printf 'no-verdict'; return; fi
  if [[ "$(jq 'length' <<<"$comments")" -gt 0 ]]; then
    printf 'changes-requested'
  else
    printf 'approved'
  fi
}

diff_tool_cleanup() {
  [[ -z "$difftool_snapshot" ]] || rm -rf "$difftool_snapshot"
}
