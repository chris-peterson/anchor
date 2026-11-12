---
name: amend
description: Fold the staged changes into the last commit — commit's flow with the amend already chosen, so tests and the review still run before it amends and pushes. Use when amending, fixing up HEAD, or folding a change into the previous commit.
---

# Amend

`/anchor:commit` decides between a new commit and an amend of HEAD, and asks.
`/anchor:amend` is for when you already know the answer. It takes away that one
question. The squash gate, the tests, the review, and the force-push question all
still apply, so this skill lands nothing that `/anchor:commit` wouldn't.

**Run `/anchor:commit`'s flow**, `${CLAUDE_PLUGIN_ROOT}/skills/commit/SKILL.md`:
the target repo, the steps, the helpers, and the execute-quietly discipline are
all the same. Read it and follow it, with the differences below. Both skills ask
the same scripts whether HEAD can be amended (`commit-preflight.sh`, which folds
in `squash-check.sh`) and amend through the same script (`commit.sh --mode amend`,
which reads the gate again at the moment it rewrites). Don't restate those rules
from memory, because then the two skills could disagree about when amending is
safe.

## Route on the pre-flight

Run Step 1 as written, then route on its block before anything else:

| Block | Route |
|-------|-------|
| `STAGED=1`, `SQUASH=allowed` | **Amend.** Continue with Step 2. Skip Step 4's squash-or-new question and the relatedness judgment, since the invocation already answered them. Step 4's default-branch guard still applies |
| `STAGED=1`, `SQUASH=blocked` | **HEAD can't be amended.** Say so in one line, `HEAD can't be amended, so this would land as a new commit`, and don't give the reason (COMMIT-12). Ask with `AskUserQuestion` (header `Amend`): **New commit** runs `/anchor:commit`'s flow from Step 2 as an ordinary new commit; **Stop** commits nothing |
| `STAGED=0` | **Message-only amend.** See below. A message-only amend never goes through the push-existing route |

## The message covers both changes

In Step 3, read HEAD's message (`git log -1 --format=%B`) and its diff
(`git show HEAD`), along with the staged diff. Then draft one message for the
amended commit, which carries both changes: the same combined message Step 4
writes for a squash.

**When HEAD's message still describes the combined change**, keep it word for
word in the message file. The message hasn't changed, so the user has nothing
to decide about it. In Step 5's manifest, replace the verbatim message block
with one line, `Message: unchanged — <subject>`. The changeset review still
runs.

## Review and amend

Step 5 is unchanged: `review-diff.sh --local --message-file` on the staged
paths. It reviews what the amend adds, not HEAD's own change, which was reviewed
when it was committed. Under the manifest's **What's next**, say that this
amends `<PRIOR_SUBJECT>`.

In Step 6, run `commit.sh --mode amend --message-file <path> --reviewed-index <REVIEW_INDEX> --path <p>...`:

- **`SQUASH_FORCE_PUSH=1`**: the amend replaces a pushed commit. Ask Step 6's
  `Force-push` question first, and add `--force-with-lease` only if the user
  approves (COMMIT-27). The invocation decided to amend. It did not approve a
  rewrite of the remote branch.
- **`--no-push`** applies here exactly as it does in `/anchor:commit`.
- **Exit 69**: the gate closed during the review (the CR was marked ready, for
  example). Nothing was committed. Offer the change as a new commit
  (`--mode new`). The drafted message describes both changes, but a new commit
  carries only the staged one, so redraft the message for that change and go
  back to Step 5 before committing.

The review record and Step 7's pipeline watch follow, as for a squash.

## Message-only amend

With nothing staged, the tree doesn't change, so there are no tests to run and no
changeset to review. Only the message changes:

- **`SQUASH=allowed`**, or **`ALLOW_MESSAGE_AMEND=1`** when the user reports
  that HEAD's message is wrong (the same bar as Step 4's exception in
  `/anchor:commit`): redraft the message from `git show HEAD` and the user's
  correction. If the redraft matches HEAD's message, say there's nothing to
  amend and stop. Otherwise follow Step 4's message-only amend: print the
  message verbatim, then ask the `Amend` question once. When the commit is
  pushed (`SQUASH_FORCE_PUSH=1`, or always under `ALLOW_MESSAGE_AMEND=1`), the
  question names the force-push. Then run
  `commit.sh --mode amend --message-file <path>` with no `--path`, and add
  `--force-with-lease` when the question named one.
- **Neither**: HEAD can't be amended and nothing is staged. Say there's nothing
  to amend and stop. If `AHEAD` is 1 or more, name `/anchor:commit` as the
  command that pushes the unpushed commits.
