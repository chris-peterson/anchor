## Step 6: Approve the exact text

Everything below posts under the user's name with nothing marking it as drafted
by an agent, so the words are theirs to approve — not a summary of them, and not
a plan describing them. The `--preview` output *is* the text; present that.

Then ask with structured choices when the host supports that (header `Post`),
or directly otherwise:

- **Post all** *(default)* — every thread plus the summary.
- **Post one at a time** — walk the numbered findings, confirming each; skip any
  the user drops.
- **Keep it local** — the review stays in the session. This is a finished
  outcome; say where the findings file is and stop.

A revision at this gate re-renders and comes back here. Approval of one round is
not approval of the next.

## Step 7: Post the approved findings

```bash
bash "<anchor-root>/scripts/review-post.sh" --post \
  --findings <FINDINGS_PATH> --forge <FORGE> --project <PROJECT> --cr <CR_IID> \
  [--host <HOST>] --base-sha <CR_BASE_SHA> --start-sha <CR_START_SHA> \
  [--index <n|summary>]
```

Without `--index` everything posts — on GitHub as one batched review so the
author gets a single notification, on GitLab as one POST per thread because it
has no batch endpoint. With `--index` it posts exactly one finding, which is
what **Post one at a time** walks.

The script re-reads the CR head before writing anything. `POST_ERROR=head-moved`
means the author pushed while the review was being written: every anchor now
points at lines that may not exist. Report the two SHAs and offer to re-run from
Step 1 against the new head — never post anyway, and never re-anchor by guessing
where the lines went.

Post what was approved. An improvement you notice while posting goes back
through Step 6.

## Step 8: Report

**After a post (Steps 6-7).** One line per finding: `#N <file:line> — posted`
plus the summary comment's outcome, and the CR URL. Say plainly what was **not**
posted — anything the user dropped, and anything that folded into the summary for
want of an anchor.

Close by naming the verdict as the user's to record, with the invocation:

```text
Comments posted. Recording a verdict is yours:
  gh pr review <n> --approve          # or --request-changes
  glab mr approve <iid>
```

**After a self-review (Step 5).** One line per finding: `#N <file:line> — fixed
in <sha>`, `— dropped`, or `— posted` for one that went out as a thread. Then the
CR's state: still a draft, or ready with whoever was requested, and the CR URL.
Nothing about a verdict — on your own CR there is none to record.

## Related

`anchor:prepare-review` writes the description this skill reads first;
`anchor:resolve-feedback` is what the author runs when these findings reach
them. The canonical forge invocations behind Step 7 — line-anchored threads on
both forges, the batched review, the position payload GitLab silently drops when
it's malformed — are in `<anchor-root>/guides/forge-cookbook.md`.
