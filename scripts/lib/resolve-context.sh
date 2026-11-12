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
# ctx_resolve_repo only ever `cd`s — it does not create anything. The other helpers
# read facts off the resolved checkout: the default branch, and whether a commit
# is in it (fetching origin once when it isn't).
#
#   CTX_REPO       (in)  a checkout to operate on directly (--repo)
#   RESOLVED_VIA   (out) `cwd` (inferred) or `repo` (--repo); the caller emits it
#                        so a fallback is never silent
#
# With CTX_REPO unset, cwd is left untouched.
#
# On a target that isn't a git working tree it prints CTX_ERROR=… on stderr and
# exits 66, rather than silently operating against the wrong (cwd) repo.

ctx_resolve_repo() {
  local target
  if [[ -n "${CTX_REPO:-}" ]]; then
    target="$CTX_REPO"
  else
    RESOLVED_VIA=cwd
    return
  fi

  if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "CTX_ERROR=--repo target is not a git working tree: $target" >&2
    exit 66
  fi
  cd "$target" || { echo "CTX_ERROR=could not cd into repo target: $target" >&2; exit 66; }
  RESOLVED_VIA=repo
}

# origin's default branch, by name: what origin/HEAD points at, else main, else
# master, whichever this checkout has. Prints nothing and returns 1 when it has
# none of them.
anchor_default_branch() {
  local ref
  for ref in "$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)" origin/main origin/master; do
    if [[ -n "$ref" ]] && git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      printf '%s\n' "${ref#origin/}"
      return 0
    fi
  done
  return 1
}

# The branch's pushed copy, as `<remote>/<branch>`: its upstream when the
# upstream carries the branch's own name. A branch created from a remote-tracking
# ref (`git switch -c <branch> origin/main`) tracks that ref under git's default
# `branch.autoSetupMerge`, and that upstream is where it started, not where it
# was pushed. Prints nothing and returns 1 for such an upstream, and with none.
anchor_pushed_ref() {
  local branch upstream
  branch=$(git symbolic-ref --quiet --short HEAD) || return 1
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || return 1
  [[ "${upstream#*/}" == "$branch" ]] || return 1
  printf '%s\n' "$upstream"
}

# Commits on a branch that was never pushed: the ones no origin ref holds. On a
# branch cut from another pushed branch rather than the default branch, the
# default branch would count that branch's commits too.
anchor_unpushed_count() {
  [[ -n "$(git for-each-ref --count=1 --format='%(refname)' refs/remotes/origin)" ]] || return 1
  git rev-list --count HEAD --not --remotes=origin
}

# The commit those unpushed commits start after: the parent of the oldest one,
# or HEAD when there are none. Returns 1 when origin has no refs here, or the
# oldest unpushed commit is a root.
anchor_unpushed_base() {
  local oldest
  [[ -n "$(git for-each-ref --count=1 --format='%(refname)' refs/remotes/origin)" ]] || return 1
  oldest=$(git rev-list --reverse --topo-order HEAD --not --remotes=origin | sed -n 1p)
  if [[ -z "$oldest" ]]; then
    git rev-parse HEAD
    return 0
  fi
  git rev-parse --verify --quiet "${oldest}^"
}

# Whether <sha> is a commit in this checkout, fetching origin once when it isn't.
anchor_fetch_commit() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1 && return 0
  git fetch --quiet origin 2>/dev/null || true
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1
}
