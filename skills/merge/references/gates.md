## Step 1: Check the merge gates

Four gates must be green before the merge. Check them in this order — cheapest and
most-blocking first — and stop at the first that fails, so the user fixes one thing
at a time. Only the **pipeline** gate resolves itself with time; the skill waits on
that one. The other three need a person (mark ready, get an approval, resolve a
thread) or a rebase, so they stop and report rather than spin.

**The gates report as one table, and that table is the whole step.** A green gate
is worth showing — together they're the evidence the merge is safe — and worth
exactly one row:

| Gate | State |
| --- | --- |
| Draft | cleared |
| Mergeable | `mergeable`, no conflicts |
| Pipeline | `success` — 3/3 jobs on `<sha>` |
| Approvals | 0 required, 0 left |
| Threads | none unresolved |

A gate that doesn't apply is a row too (`none for this commit`, `no approval
rules`). A gate that blocks ends the flow, so it gets the rows checked above it
plus what blocked and what clears it. Either way the commands, the raw forge
fields, and the reasoning that read them stay out.

### 1a. Marked ready (not draft)

A draft CR is the author's "not under review yet" flag; merging one skips the review
it's waiting for. If the resolved CR is a draft (`isDraft` / `.draft` true), stop and
ask whether to mark it ready and proceed — don't mark it ready silently:

> This CR is still a draft. Marking it ready requests review; merging now lands it
> without that review. Mark ready and merge anyway? `[yes / no]`

On `yes`, clear the flag through the helper rather than the CLI directly. It reads
the flag fresh, and announces `cr.ready` so a sibling tracking deliverables sees
the CR leave draft:

```bash
bash "<anchor-root>/scripts/mark-ready.sh" --forge <FORGE> --cr <CR_IID>
```

`CR_READY=ok` and continue. `ALREADY_READY=1` means the CR stopped being a draft
between Step 0's read and now, which satisfies this gate too, so continue without
reporting a change you didn't make. On `no`, stop.

### 1b. Mergeable (no conflicts)

Read the forge's mergeable state (cookbook: "Check a CR's mergeable state"). If the
CR conflicts with the target branch or is behind it in a way the forge won't
auto-resolve, stop and route to a rebase — `anchor:prepare-review` owns the
rebase-on-default flow. Don't attempt the merge; the forge would reject it anyway.

### 1c. Pipeline green — wait if it's still running

Resolve the pipeline for the CR head and read its state with the pipeline helper
(the same one `anchor:pipeline` uses), so the poll loop, forge normalization, and
failed-job reporting are shared rather than re-derived:

```bash
bash "<anchor-root>/scripts/pipeline-status.sh" --single-run
```

`--single-run` keeps this gate on one run — the commit's most recent. On GitHub a
commit carries a run per workflow, and `anchor:pipeline` folds them into one
verdict; that isn't this gate's question. Whether *every* required check passed is
the forge's own merge check, read in step 1a, and duplicating it here would block
a merge the forge is willing to take.

Map `PIPELINE_STATE`:

- **`success`** — gate passes; continue.
- **`running` / `pending`** — the pipeline hasn't settled. **Don't hand control
  back for the user to re-ask later** — watch it here. Re-launch the helper with
  `--watch` with the host's background/session mechanism and retain its handle (a
  foreground call holds the turn open until the command timeout), then read the
  settled verdict through that mechanism (not `tail` / `$(...)`, which trip the
  command-substitution gate):

  ```bash
  bash "<anchor-root>/scripts/pipeline-status.sh" --single-run --watch
  ```

  When it settles, re-map the terminal state below. If `PIPELINE_TIMEOUT=1` (the
  watch ceiling elapsed), report the last state and offer to keep watching with a
  longer `--timeout` rather than merging on an unsettled pipeline.
- **`failed` / `canceled`** — stop. List each job from `PIPELINE_FAILED_JOBS` (name
  linked to its url) and the `PIPELINE_URL`, exactly as `anchor:pipeline` reports.
  A red pipeline is a blocked merge; offer to look at a failed job's log rather than
  fetching it unprompted.
- **`manual`** — the pipeline is blocked awaiting a manual action; it won't progress
  on its own. Say so and stop.
- **`none`** — no pipeline for this commit (path/branch filters, or the repo has no
  CI for this ref). Treat as "no pipeline gate", not a failure — note it and
  continue.
- **`absent`** — origin isn't a recognized forge; there's no pipeline to gate on.

### 1d. Approvals satisfied

Read the CR's approval state (cookbook: "Check a CR's approvals"). If required
approvals are missing — GitHub `reviewDecision` is `REVIEW_REQUIRED` or
`CHANGES_REQUESTED`; GitLab `approvals_left > 0` — stop and report who still needs
to approve. This gate needs a reviewer; the skill can't clear it. On
`CHANGES_REQUESTED` specifically, point the user at `anchor:resolve-feedback`.

Where a repo has no approval rules configured, there's nothing to satisfy — don't
invent a requirement; continue.

### 1e. Review threads resolved

Fetch unresolved, human-authored review threads (cookbook: "List unresolved review
threads" — the same query `anchor:resolve-feedback` uses). If any remain, surface
them in one line each (`<file:line> — @reviewer — <ask>`) and confirm before
landing:

> `<n>` review threads are still unresolved. Merge anyway, or resolve them first?
> `[merge / resolve first]`

On `resolve first`, hand off to `anchor:resolve-feedback` and stop. On `merge`,
continue — some threads are intentionally left open (answered questions the asker
never marked resolved), and the author is the one who knows.
