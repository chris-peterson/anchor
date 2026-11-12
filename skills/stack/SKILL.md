---
name: stack
description: Work with a stack of change requests, each built on the one below. Show the stack as a tree with each CR's state, start the next branch on top of the current one, move a branch onto another CR or base, link the stack as one GitHub stack, and review the stack from the bottom up. Use when stacking work, starting a branch on top of another, changing a CR's base or target, showing or checking a stack of PRs/MRs, linking PRs into a GitHub stack, or reviewing a stack bottom to top.
---

# Stack

A stack splits one large change into CRs a reviewer can take one at a time,
each targeting the branch of the CR below it so its diff holds only its own
commits. That only works while every CR targets the right branch: one opened
against the default branch repeats every commit beneath it, and nobody can see
which CR merges first. This skill keeps the stack legible and in order.

**Don't narrate your work.** Follow `${CLAUDE_PLUGIN_ROOT}/guides/execute-quietly.md`.
What's worth surfacing is the tree, a question that needs the user, and the
result.

Every forge read, the retarget, and the link run inside `scripts/stack.sh`;
every rebase and force-push runs inside `/anchor:rebase`. Don't call
`gh pr edit`, `gh stack`, `glab mr update`, `git rebase`, or `git push`
yourself.

## Pick the mode

| The user says | Mode |
| --- | --- |
| `/anchor:stack`, "show the stack", "render the stack" | **Show** |
| `/anchor:stack <description of the next piece of work>` | **New** |
| `/anchor:stack on <cr-or-branch>`, "stack onto !150", "change the base to …" | **Move** |
| `/anchor:stack link`, "make it a GitHub stack", "create the stack on GitHub" | **Link** |
| `/anchor:stack review`, `/anchor:stack /anchor:review`, "review the stack bottom to top" | **Review** |

`--all` widens Show and Review from the stacks holding your CRs or the current
branch to every stack in the repo. Pass `--repo <checkout>` when the stack lives
in another checkout; resolve a repo given by name with
`${CLAUDE_PLUGIN_ROOT}/scripts/resolve-target.sh`, as the forge cookbook's
"Resolving a named target repo" describes.

On every subcommand, `STACK_ERROR=…` stops the flow: surface it, and with
`STACK_AUTH=1` ask for fresh credentials rather than retrying.

## Show

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stack.sh" show [--all] [--repo <checkout>]
```

Print the `TREE` lines verbatim in a fenced `text` block, an empty `TREE=`
being a blank line between two stacks. The tree reads top to bottom in merge
order, and each `└` sits on the CR above it. With `STACK_TREES=0`, say no open
CR is yours or on the current branch, and name `--all`.

After the tree, one line for each thing to act on, and nothing for a CR in good
order:

- **A CR flagged `stacked-on:<branch>`** targets the default branch though its
  commits sit on `<branch>`'s CR, so its diff repeats the CRs below it. When it
  is the current branch, offer **Move** onto that CR. Otherwise name the branch
  to check out and run `/anchor:stack on <ref>` from.
- **A CR flagged `base-not-open`** targets a branch with no open CR: the CR
  below it merged or closed. Offer **Move** onto the default branch.
- **`merge` is `now`** on the bottom CR: name `/anchor:merge`.
- **`NATIVE_STACK=unlinked`**: the PRs target each other, but GitHub doesn't
  hold them as one stack, so they get no stack view or stack number. Offer
  **Link**.
- **`NATIVE_STACK=no-gh-stack`**: the same, and linking needs the gh-stack
  extension. Name `gh extension install github/gh-stack`, then
  `/anchor:stack link`.
- **`FETCH_ERROR`**: the fetch failed, so no CR's base was checked. Say so in
  one line.

## New

Derive the branch name from the description: a few words in kebab-case, in the
shape the repo's recent branches use (`git branch -r --sort=-committerdate`).
Then cut it on top of the current branch:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stack.sh" new <branch> [--repo <checkout>]
```

It switches to `NEW_BRANCH`, starting at the current commit, and carries any
uncommitted changes with it. Report the branch and what it sits on, and add
the line that applies:

- `STACKED=0`: the current branch is the default branch, so this is an
  ordinary branch, not a stacked one.
- `BASE_CR_REF` set: when this branch's CR opens, `/anchor:prepare-review`
  stacks it on `BASE_CR_REF`.
- `BASE_CR_REF` empty, `BASE_PUSHED=1`: `BASE_BRANCH` has no CR yet. Open one
  first, or open this one with `/anchor:prepare-review --onto <BASE_BRANCH>`.
- `BASE_PUSHED=0`: `BASE_BRANCH` was never pushed, so a CR can't target it yet.
  `/anchor:commit` on it pushes it.

## Move

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stack.sh" retarget --onto <cr-or-branch> [--allow-others] [--repo <checkout>]
```

`--onto` takes a CR (`#150`, `!150`, `150`, its URL) or a branch.

| Result | Then |
| --- | --- |
| `RETARGET=done` | the CR now targets `NEW_TARGET`; rebase onto it (below) |
| `RETARGET=unchanged` | it already did; rebase onto it (below) |
| `RETARGET=no-cr` | the branch has no CR; run `/anchor:rebase --onto <branch>`, naming the branch `--onto` resolved to |
| exit 66, `CONFIRM_OTHERS=<cr>:<author>` | someone else opened that CR, and moving its base changes what its reviewers see. Ask (header `Retarget`): **Retarget** (re-run with `--allow-others`) or **Stop** |

To rebase, continue with `/anchor:rebase`. It follows the CR's target, so it
rebases onto `NEW_TARGET`, asking before any force-push it needs to. Where the
commits already sit on the new base, as when only the target was wrong, it
reports the branch up to date, and the move was the retarget alone.

If the rebase stops without finishing (aborted, or the user stops at a
conflict), the CR targets the new base while the branch doesn't sit on it, so
its diff is wrong until it does. Say so, and offer to put the target back:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stack.sh" retarget --onto <PREVIOUS_TARGET> [--repo <checkout>]
```

## Link

GitHub only. Chained targets order the PRs for git, but GitHub shows them as a
stack (its stack view, a stack number on each PR) only once they are linked.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stack.sh" link [--allow-others] [--repo <checkout>]
```

It links the stack holding the current branch, bottom to top, through the
gh-stack extension (`gh stack link`). Draft state and targets stay as they are.

| Result | Then |
| --- | --- |
| `LINK=done` | report `LINK_ORDER` as GitHub stack `NATIVE_STACK_NUMBER` |
| `LINK=unchanged` | GitHub already holds them as that stack; say so |
| exit 66, `CONFIRM_OTHERS=<cr>:<author>,…` | someone else opened those PRs, and linking puts them in a stack their reviewers see. Ask (header `Link`): **Link** (re-run with `--allow-others`) or **Stop** |

`STACK_ERROR` names why it can't link: a PR whose target disagrees with where
it sits (offer **Move** first), a stack that forks (a GitHub stack is one line),
or the gh-stack extension missing (name the install command).

## Review

Run **Show** first and print the tree. `STACK_ORDER` lists the stack holding the
current branch, bottom to top; when it's empty, no open stack holds the current
branch, so say that and stop. A CR flagged `stacked-on` would show its reviewer
every commit below it, so offer **Move** for it before the review reaches it.

Then review each CR in `STACK_ORDER` with `/anchor:review <number>`, one at a
time and bottom first. Each one targets the CR below, so its review covers its
own commits alone. Each review runs to its own end, including the fix commits
or posted findings it settles on. Between two, ask (header `Stack review`):
**Review `<next ref>`** or **Stop here**. A fix that changes a CR lower in the
stack leaves the ones above it behind their base, so after the last review,
name `/anchor:rebase` and its cascade when any review committed a fix.

## Report

One line for what changed, and the tree when the stack changed shape:

> Retargeted #53 onto `drop-allow-promotion` (#52); already up to date, so
> nothing was pushed.
