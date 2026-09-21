## Step 4: Settle the branch and shape

Nothing is committed in this step — it settles *where* and *how* the commit lands: the branch to commit on, and whether this is a new commit or a squash. The **message itself isn't confirmed here** — it rides into the Step 5 review, where you read it beside the diff.

**Show the `--stat` summary from Step 1 only when this step actually asks the user something** — the branch prompt or the squash prompt below. There it's the scope the choice applies to. On the path where neither fires (the ordinary `SQUASH=blocked` commit on a feature branch, which is the common one), there is no question for it to qualify, and Step 5's review opens on the same changeset moments later; printing it there is a line of output attached to no decision.

### When on the default branch — create a feature branch first

The commit **pushes** (Step 6), so landing directly on the default branch publishes to it. Step 1's block already resolved this: `ON_DEFAULT_BRANCH=1` (HEAD is `DEFAULT_BRANCH`) is the case to guard. **When it's `1`, don't commit onto the default branch** — a commit meant for a CR belongs on a feature branch, and pushing to the default branch directly lands the work with no CR for anyone else to review. Step 5 reviews the diff and the message on both paths; what the default branch skips is the CR, not the user's own look at the change — so describe this choice as landing without a CR, never as skipping or bypassing review. Offer the branch, named from the subject you just drafted:

- **Slug the subject** — lowercase, non-alphanumeric runs → single hyphens, trim leading/trailing hyphens, cap ~50 chars. `Add retry to checkout` → `add-retry-to-checkout`.
- Ask as structured choices when the host supports that (header `Branch`), or
  directly with the same options otherwise. Put the recommendation first so the
  default lands on branch creation:
  1. **Create branch `<slug>`** *(recommended)* — `git checkout -b <slug>`, then the rest of the flow commits and pushes onto it.
  2. **Commit to `<default>`** — the deliberate, explicit direct-to-default case (a release commit, a docs typo on `main`); the flow proceeds and pushes to the default branch, so the change lands without a CR. Never the default path.
  3. **Edit name** — take a name from the user, then `git checkout -b <that>`.

Create the branch (when chosen) **before** the commit, so the commit lands — and pushes — on the feature branch. Once `commit` pushes that branch, `prepare-review` opens the CR against it (it operates on an already-pushed branch and never pushes itself).

Committing directly to the default branch is never a squash target — the gate below returns `SQUASH=blocked`, so even the "commit to `<default>`" path lands as a new commit rather than amending the published tip.

### Squash gate

Whether squashing the staged changes into HEAD (via `git commit --amend` in Step 6) is on the table comes from **Step 1's block** — the gate is *"is HEAD out for review?"*, decided by `squash-check.sh` (folded into the recon), which returns only what you act on:

| Key | What to do with it |
|-----|--------------------|
| `SQUASH` | `allowed` → amending HEAD is safe; offer squash (gated further by relatedness below). `blocked` → the ordinary new commit (below) |
| `SQUASH_FORCE_PUSH` | meaningful only when `allowed`: `1` → HEAD is pushed (a draft CR, or no CR), so the amend must be followed by `git push --force-with-lease` in Step 6 |
| `ALLOW_MESSAGE_AMEND` | `1` → squash is `blocked`, but a message-only amend is permitted (the ready-CR case); gates the exception below. `0` → no amend of any kind |
| `PRIOR_SUBJECT` | HEAD's subject, for the squash option text |

The gate folds the push-state probe (including the no-upstream `origin/<default>..HEAD` fallback), the author guard, and the CR-draft probe into that decision — don't re-run them. It deliberately does **not** emit *why* squash is blocked: the block reason, push count, CR state, and author identity stay inside the script, so there's nothing here to narrate or keep quiet by hand (`<anchor-root>/guides/execute-quietly.md`).

### When `SQUASH=blocked` — the ordinary commit

The vanilla path, and the common one: HEAD isn't yours to rewrite or it's out for review, so a plain new commit is the only sensible outcome — exactly what the user asked for when they said "commit." Nothing to confirm here — the message is reviewed in Step 5, and the shape is a **new commit**, so proceed straight to Step 5. The user never raised squashing; don't mention it.

**Narrow exception — message-only amend (`ALLOW_MESSAGE_AMEND=1`).** When the helper permits a message-only amend and the user reports the *message* (not the code) is demonstrably wrong — pasted from a different repo, references identifiers that don't exist here, doesn't match what the diff does — the tree is unchanged, so the reviewer-protection motivation doesn't apply. Plan a message-only amend via Step 6's `commit.sh --mode amend --force-with-lease` to fix the message (there is no tree change to review, so this skips Step 5), and surface "force-push (`--force-with-lease`) affects only the message; the tree is unchanged" as an explicit choice in Step 6. The flag fires only where this is safe (a ready CR whose tree a message fix leaves untouched); when it's `0`, no amend — a new commit is the only path. Do not extend it to content rewrites; the moment any file content moves, the standard gate applies again.

### When `SQUASH=allowed` — apply the relatedness judgment

The gate is open; now *your* judgment decides squash vs new commit. Decide whether the staged changes are **related** to the prior commit (continuation, fix, or refinement of the same work) or **unrelated** (different topic, different files, new task):

- **Related** → recommend squash
- **Unrelated** → recommend new commit

When `SQUASH_FORCE_PUSH=1` (pushed draft CR), annotate the squash option so the user knows the follow-up push is a force-push — e.g. `_(CR is draft — mutable history is the norm; amend force-pushes with lease)_`. Don't let it flip the recommendation; a draft's history is expected to move.

Present the two options in recommended-first order (the message is reviewed in Step 5, so there's no message-edit option here):

If recommending a new commit:

1) **New commit** _(* recommended)_
2) **Squash into "[PRIOR_SUBJECT]"**

If recommending squash:

1) **Squash into "[PRIOR_SUBJECT]"** _(* recommended)_
2) **New commit**

Record the choice (new commit vs squash) and proceed to Step 5; the review runs before either is executed.
