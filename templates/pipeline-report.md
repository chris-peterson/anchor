# Pipeline report template

The shape of a pipeline report: the headline, the table of runs and jobs, and
what each state's emoji means. The `pipeline` skill owns the *technique* —
resolving the commit, choosing one-shot vs. watch, tracking a single job. This
file owns the *shape*, so it's the place to edit as your preferences evolve.

Every caller that reports a pipeline reads this file, so the report is the same
whether the user asked for it (`/anchor:pipeline`) or a push produced it
(`commit`, `resolve-feedback`, `prepare-review` — see the "after a push"
section below).

## The headline

One line, from `PIPELINE_STATE`, with `PIPELINE_URL` linked:

- `✅ Pipeline passed` · `❌ Pipeline failed` · `⚠️ Pipeline canceled`
- `⏭️ Pipeline skipped` · `⏸️ Pipeline blocked on a manual action`
- `🔄 Pipeline still running` *(one-shot reads and a watch that hit its ceiling)*

Say **workflow run** on GitHub only where the distinction matters to what the
user does next; *pipeline* is the word for both otherwise.

## The table

Below the headline, one row per job from `PIPELINE_RUNS`, ordered worst state
first so what wants attention is at the top. Job names link to their `url`:

```markdown
| | Job | Workflow | State |
|---|---|---|---|
| ❌ | [unit](https://…/job/1) | Test | failed |
| ⏭️ | [e2e](https://…/job/2) | Test | skipped |
| ✅ | [style](https://…/job/9) | Lint | success |
```

- **Third column** — the workflow on GitHub, the stage on GitLab (`jobs[].stage`).
  Label it accordingly; a GitLab table's header reads `Stage`.
- **A run with no jobs** gets one row for the run itself, named for its workflow.
  A workflow that reports `skipped` before creating any job is the common case.
- **Name absent signals as absent.** A job the forge hasn't created yet is
  `none` — report it as *not started*, never as passing.

## The emoji

Keyed off the normalized state, so the reader sees whether a row wants attention
without reading the word:

| Emoji | State | Reads as |
|---|---|---|
| ✅ | `success` | expected |
| ❌ | `failed` | wants attention |
| ⚠️ | `canceled` | wants attention |
| ⏭️ | `skipped` | expected; nothing to do |
| ⏸️ | `manual` | expected; won't progress on its own |
| 🔄 | `running` / `pending` | still in flight |

`skipped` and `manual` are not failures. They're split off from `❌` precisely so
a reader scanning for red doesn't stop on a path filter or a deploy gate.

## When there is no table

Report these in one line, with no table — there are no rows to draw:

- **`none`** — no pipeline for this commit. Common causes: path or branch
  filters excluded it, the commit isn't pushed, or the repo has no CI for this
  ref. State it; it isn't a failure.
- **`absent`** — the `origin` remote isn't GitHub or GitLab, so there's no
  pipeline to report.
- **Job mode** (`--job <name>`) — the ask was about one job, so report that job's
  state and link, with the parent pipeline for context.

## After a push

When the report follows a push rather than an explicit ask, the shape above is
unchanged; only these hold in addition:

- **The headline carries the branch** the push landed on, so a report arriving
  after the fact is unambiguous about what it describes.
- **On `⏭️`/`⏸️`/`🔄`, say what the user's next move is** — a blocked pipeline
  won't progress on its own, and a timed-out watch can be resumed.
- **One report per pipeline.** The skills gate on the runs they've reported, so
  a CR opened on a commit whose pipeline was already reported doesn't report it
  twice — while a pipeline that only the CR started is still a first report.
