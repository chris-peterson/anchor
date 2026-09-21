### Rebase on the default branch when `BEHIND > 0`

`BEHIND=0` → skip this section. Otherwise the branch needs `origin/<default>` before it can merge — every conflict with intervening commits has to be resolved before the CR can land, and doing it now (while the change is fresh) is cheaper than after review when context has gone cold. Secondary: deep links anchor to lines in the *current* diff, so a behind-default branch points at content that won't compose cleanly at merge time. Ask:

> Branch is `<BEHIND>` commits behind `origin/<default>`. Rebase now? `[yes / skip]`

- `yes` — run `git rebase origin/<default>`. On conflict, resolve in place: read both sides of each conflicted region, pick the resolution that preserves the intent of *both* changes (not just one side), `git add` the resolved files, then `git rebase --continue`. Loop until the rebase completes. Surface to the user when intent is genuinely ambiguous — two competing changes to the same logic, semantic conflicts the textual markers don't show, a rename colliding with an edit. Don't guess in those cases; show the conflict and ask. If a hook fails mid-rebase, surface the failure rather than retrying with `--no-verify`.
- `skip` — proceed with the current branch state. Note that deep links may render against lines that have shifted by merge time.

A rebase rewrites history, so the push that follows is a force-push. Gate it on `CR_DRAFT` — the author's declared review state, which is reliable in a way that inferred engagement signals (note counts, reviewer lists) are not:

**`CR_PENDING=1`** (no CR yet) — nothing is out for review, so nothing can be disturbed. Rebase and force-push with lease.

**`CR_DRAFT=true`** — mutable history is the norm (`anchor` opens CRs as drafts for exactly this reason). Rebase and force-push with lease without further ceremony.

**`CR_DRAFT=false`** (ready) — a reviewer may already be looking, and there's no reliable signal for whether they have. Force-pushing over commits they've seen destroys their "changes since you last looked" diff and marks inline threads outdated. Engagement signals are advisory context for the prompt (reviewers / discussion count via `glab api projects/:fullpath/merge_requests/<CR_IID> | jq '{reviewers, user_notes_count}'` or `gh pr view --json reviews,reviewRequests,comments`), but the decision is the user's — ask before proceeding:

> This CR is marked ready. Rebasing now force-pushes over commits a reviewer may have seen, which resets their incremental diff. Rebase anyway? `[yes / skip]`

After a successful rebase (and the review-activity check above), force-push with lease so the open CR updates to the rewritten history:

```bash
git push --force-with-lease
```

`--force-with-lease` rejects the push if anyone else has pushed to the branch since you last fetched — that's the safety against clobbering a coworker's commit. If it rejects, fetch, inspect, and ask the user before escalating. If the rebase itself aborts (uncommitted changes blocking it, a rebase already in progress, missing remote), surface the error and stop.

### Read the diff and commit history

Substitute `DEFAULT_BRANCH` from the block for `main`:

```bash
git log main..HEAD --oneline
```

```bash
git diff main...HEAD --stat
```

```bash
git diff main...HEAD
```

(`AHEAD=0` already routed you — chained to `anchor:commit` on `NEEDS_COMMIT=1`, or stopped otherwise — so a run that reaches here is ahead of the default branch.)

### Act on `STATE`

The deep links you'll generate point at specific lines of the *current* CR diff, so drafting against stale state ships a description that renders against content the reviewer can't see. `STATE=match` → proceed. Otherwise stop and surface — *do not* draft:

- **`dirty`** — uncommitted changes in the working tree. Say exactly that and stop:

  > Uncommitted changes detected — commit them first, then re-run.

  Nothing else. The user knows what they changed and why it isn't committed, so a diagnosis of *how* the tree got dirty, and an explanation of why a description can't be drafted against it, is a paragraph they have to read to reach the one word they need (`commit`). Offer to chain into `anchor:commit` if they want it.
- **`head-mismatch`** — local HEAD ≠ CR head: the user's expected push hasn't landed, or you're on the wrong branch. Common cause: a force-push blocked by a hook, or a no-op push because the working tree was never committed. Surface the SHA mismatch (`LOCAL_HEAD_SHA` vs `CR_HEAD_SHA`) and ask.
- **`dirty+head-mismatch`** — lead with the uncommitted-changes line above; the push is the same fix, so don't report the SHA mismatch as a second problem to solve.

State drift between conversation belief and repo reality is silent and expensive. The script's read-only state check catches it; missing it ships a broken description.
