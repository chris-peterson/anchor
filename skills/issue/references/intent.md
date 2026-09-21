## Step 1: Resolve the issue

Pick the forge per **Target repo** above (`gh` for GitHub, `glab` for GitLab).

- **An issue URL or number was provided** → **update** that issue. Pull its current body to a temp file now (`$(mktemp -u /tmp/issue-current.XXXXXX).md`); Step 6 diffs the draft against it:

  ```bash
  # GitHub
  gh issue view <num> --json body --jq '.body' > <current-path>
  ```

  ```bash
  # GitLab
  glab issue view <iid> --output json | jq -r '.description' > <current-path>
  ```

- **No issue reference** → **create** a new issue.

## Step 2: Gather intent before drafting

There is no diff to mine, so the author's answers *are* the issue. Ask for what's missing — don't draft around a gap:

- **Why** — what problem this solves or what need it serves, and why it matters now.
- **Consumer** — who is the primary caller or consumer of the change?
- **Acceptance** — what does "done" look like? Concrete criteria or scenarios.
- **Approach** *(if the author has one in mind)* — the intended plan and any key design decisions. If they don't yet, the issue can be a problem statement without a proposed approach; don't invent one.

Wait for answers before drafting. If the only open item is the WHY, ask:

> **What problem does this solve, and why does it matter?** A sentence or two is enough — and who's the primary consumer of the change?

## Step 3: Guard against duplicates

This step runs only on the **create** path — skip it when updating a known issue. A duplicate issue splits the discussion, so before drafting a brand-new issue, make sure one doesn't already cover this need.

Finding and picking issues is the `backlog` skill's job — don't re-implement a forge search here. If it's unclear whether this need is already tracked, say so and offer to run `backlog` (scoped to a keyword or two distilled from the intent — the subject of the work, not the WHY prose) to survey open and closed issues first. If the user already knows it's new, or a quick look turns up nothing that genuinely overlaps, continue to Step 4 without further comment.

If it turns out the need *is* already tracked, this is an update, not a new issue: take that issue's number and switch to the update path — fetch its current body as the baseline (the Step 1 fetch), then draft against it.
