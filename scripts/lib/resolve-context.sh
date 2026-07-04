#!/usr/bin/env bash
# Shared explicit-remote-context resolution for anchor's forge scripts.
#
# Sourced, not executed. anchor's forge scripts default to the repo backing the
# current working directory — correct when the cwd repo IS the repo the work
# targets, wrong when they differ (an MR meant for repo B gets driven against
# repo A because A is the cwd). This library lets a script accept an explicit
# target checkout and operate against it instead.
#
# Why `cd`, not `git -C` / `-R` everywhere: the Claude Code harness resets cwd
# between Bash *tool calls*, but a script runs as one process — a `cd` at the
# top persists for the whole script. So a single `cd` retargets every downstream
# `git`, `gh`, and `glab` call transparently, with no per-command flag threading.
# It also sidesteps the `glab mr create -R` trap (that flag is ignored and the
# create uses the cwd repo as the source project → a 422 fork-mismatch); running
# *inside* the target checkout has no such gap.
#
# This library only ever `cd`s — it does not create anything. Two explicit
# targets, both just a checkout to step into:
#
#   CTX_REPO       (in)  a checkout to operate on directly (--repo)
#   CTX_WORKTREE   (in)  an isolated worktree to operate in (--worktree), created
#                        and torn down by the *flow* via worktree.sh — see below
#   RESOLVED_VIA   (out) `cwd` (inferred), `repo` (--repo), or `worktree`
#                        (--worktree); the caller emits it so a fallback is never
#                        silent
#
# CTX_WORKTREE wins over CTX_REPO when both are set (the flow has already
# isolated). With neither, cwd is left untouched — today's behavior, byte-for-byte.
#
# Worktree isolation (the "wandered outside the start dir → use a worktree"
# rule) is owned by scripts/worktree.sh, not here: it decides direct-vs-worktree,
# creates the worktree once, and the skill tears it down at flow end. These
# scripts only ever step into whatever checkout they're pointed at, so the
# worktree can outlive any single one of them (the isolation would be pointless
# if each script created and removed its own).
#
# On a target that isn't a git working tree it prints CTX_ERROR=… on stderr and
# exits 66, rather than silently operating against the wrong (cwd) repo.

ctx_resolve_repo() {
  local target via
  if [[ -n "${CTX_WORKTREE:-}" ]]; then
    target="$CTX_WORKTREE"; via=worktree
  elif [[ -n "${CTX_REPO:-}" ]]; then
    target="$CTX_REPO"; via=repo
  else
    RESOLVED_VIA=cwd
    return
  fi

  if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "CTX_ERROR=--$via target is not a git working tree: $target" >&2
    exit 66
  fi
  cd "$target" || { echo "CTX_ERROR=could not cd into $via target: $target" >&2; exit 66; }
  RESOLVED_VIA="$via"
}
