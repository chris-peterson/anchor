---
name: rebase
description: Rebase the current branch on its base branch (the CR's target, or the branch it's stacked on), or a whole stack bottom-up, resolve conflicts, and force-push what was already pushed. Use when rebasing, catching a branch up to main, or when a CR is behind its target or has conflicts.
---

# Rebase

Bring a branch up to date with the branch it will merge into. Every conflict with
the commits that landed since it was cut has to be resolved before the change
can merge, and resolving them while the change is fresh is cheaper than after
review, when the context has gone cold.

**Don't narrate your work.** Follow `${CLAUDE_PLUGIN_ROOT}/guides/execute-quietly.md`.
The things worth surfacing are a question that needs the user, a conflict whose
intent is ambiguous, and the result.

The invocation is the user's decision to rebase and to force-push the result.
Two pushes still get their own question, because they cost someone else: one
over a CR marked ready, where a reviewer may already have looked, and one over a
branch whose CR someone else opened. The script stops before either (exit 66).
Every git step runs inside `scripts/rebase.sh`; don't run `git rebase` or
`git push` yourself.

## Step 1: Read the branch

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/rebase.sh" --check [--onto <branch>] [--repo <checkout>]
```

Pass `--onto` when the user named the branch to rebase onto, and `--repo` when
the branch lives in a checkout other than the working directory (resolve a repo
given by name with `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-target.sh`, as the
forge cookbook's "Resolving a named target repo" describes).

| Key | What to do with it |
|-----|--------------------|
| `REBASE_ERROR=…` | an `--onto` origin doesn't have, or one the open CR's target disagrees with. Surface it and stop |
| `PLAN_PENDING=1` | an earlier run stopped on a conflict. Ask (header `Rebase`): **Continue it** (Step 3) or **Abort it** (`rebase.sh --abort`) |
| `REBASE_IN_PROGRESS=1`, `PLAN_PENDING=0` | a rebase started outside anchor. Show `git status` and stop |
| `STACK_LOOKUP_ERROR` | the open-CR listing failed, so the base can't be resolved. Surface it and stop; on an auth failure ask for fresh credentials |
| `STACK_CHAIN` non-empty | the branch is stacked (see below) |

Everything else (uncommitted changes, a branch origin holds newer commits of, a
branch already up to date) the run itself refuses or reports, so go to Step 2.

### A stacked branch

`STACK_CHAIN` lists the branches under this one, lowest first, down to the
default branch, and each `STACK_BRANCH` line gives one's CR, draft flag, and
author (`<branch>:<cr>:<draft>:<author>`). Ask once (header `Rebase`), marking a
branch whose author isn't `VIEWER` with its owner:

- **Cascade the stack** (recommended): rebase `<lowest>` onto
  `origin/<DEFAULT_BRANCH>`, then each branch above onto the rebased one below,
  ending with `<BRANCH>`. Name the branches in order.
- **Only `<BRANCH>`**: rebase it onto `origin/<BASE_BRANCH>` as that branch
  stands.

## Step 2: Rebase

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/rebase.sh" [--cascade] [--allow-ready] [--allow-others] [--onto <branch>] [--repo <checkout>]
```

The script fast-forwards the local default branch to origin's, rebases, and
force-pushes each branch origin held as it stood, leased on that commit. Read
the exit status and the block:

| Exit / key | What to do with it |
|------------|--------------------|
| 0, `REBASE_STATUS=done` | report (below) |
| 66, `REBASE_STATUS=needs-confirmation` | nothing has moved; ask (below), then run again with the flags the answer allows |
| 0, `REBASE_STATUS=up-to-date` | already on its base; report that, it's a success |
| 0, `REBASE_STATUS=default-branch` | HEAD is the default branch, which is now level with origin's; report that |
| 75, `REBASE_STATUS=conflict` | resolve `CONFLICT_FILES` on `CONFLICT_BRANCH` (Step 3) |
| 1, `REBASE_ERROR=…` | surface it and stop. Nothing was rewritten unless the message says to run `--abort` |
| 1, `PUSH_ERROR=…` | the lease refused a push: someone pushed to that branch since the check. Show what arrived (`git log --oneline HEAD..origin/<branch>` after a fetch) and ask before anything else |

### Confirm a push that costs someone else

Ask one question (header `Force-push`) naming every line, then re-run Step 2
with the same flags plus the ones approved:

- `CONFIRM_READY=<branch>:<cr>`: the CR is marked ready, and a force-push resets
  a reviewer's "changes since you last looked" diff and marks inline threads
  outdated. Approving adds `--allow-ready`.
- `CONFIRM_OTHERS=<branch>:<cr>:<author>`: `<author>` opened that CR, so the
  push rewrites a branch they may have checked out. Approving adds
  `--allow-others`.

Options: **Force-push** (both flags the lines call for), **Stop**. With both kinds
present and the user wanting only one, an answer naming it is the answer: a
cascade with an unapproved branch can't run, so say that and stop.

## Step 3: Resolve a conflict

Edit each file in `CONFLICT_FILES` to preserve the intent of *both* sides, not
just one: read both sides of each region, then write the combined result
without the markers. Then:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/rebase.sh" --continue [--repo <checkout>]
```

It stages the files, refuses any still holding markers, continues the rebase,
and carries on with the rest of the plan (the branches above, in a cascade), so
it can stop at 75 again. Loop until it exits 0.

Stop and show the conflict when its intent is genuinely ambiguous: two competing
changes to the same logic, a semantic conflict the markers don't show, a rename
colliding with an edit. Don't guess in those cases; the user decides, or
`rebase.sh --abort` puts every branch back where it was. A hook that fails
mid-rebase arrives as `REBASE_ERROR`: surface it, never bypass it with
`--no-verify`.

## Step 4: Pipeline and report

When a `RESULT` line says `pushed`, report the pipeline the new head starts, as
`${CLAUDE_PLUGIN_ROOT}/guides/watching-a-pipeline.md` describes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-after-push.sh" --skill rebase [--repo <checkout>]
```

Then one line per `RESULT` (`<branch>:<rebased|unchanged>:<push>`), and the
pipeline:

- `pushed`: force-pushed with lease.
- `not-pushed-ahead`: the branch had commits that weren't pushed yet. Pushing
  them would publish work nobody has reviewed, so name `/anchor:commit`, which
  reviews them and pushes.
- `not-pushed-unpushed`: origin has no copy; `/anchor:commit` pushes it.

Name `DEFAULT_FF` only when it's `diverged` (the local default branch holds
commits origin lacks) or `refused`.

For each `NOTIFY=<branch>:<cr>:<author>`, the push rewrote a branch someone else
owns, so give the user a message to send them, in a fenced block they can copy
as is:

```text
Heads up @<author>: I rebased <branch> (<cr>) onto <its base> as part of
rebasing my stacked branch, and force-pushed it. If you have it checked out
with no local commits, `git fetch && git reset --hard origin/<branch>` picks it
up; with local commits, `git pull --rebase`.
```

> Rebased `feat` onto `origin/main`, one conflict resolved, force-pushed with
> lease. Pipeline: passed on `<sha>`.
