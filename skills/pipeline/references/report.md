## Report

Follow the report shape in `<anchor-root>/templates/pipeline-report.md`:
the headline from `PIPELINE_STATE`, then a table of every job in `PIPELINE_RUNS`
with a per-state emoji. The template owns the *shape* — which emoji means what,
the column set, the cases that get no table. Report that and nothing more.

The technique the shape doesn't cover:

- **`failed`** → after the table, offer to look at a failed job's log if the
  user wants to dig in. Don't fetch logs unprompted. `PIPELINE_FAILED_JOBS`
  names the verdict run's failures; the table already carries the rest.
- **`running` / `pending`** *(one-shot only — watch mode never returns here)* →
  offer to watch.
- **`none` under `--workflow`** → that workflow has no run for this commit.
  Check the name against the repo's workflow files before reporting a gap; a
  typo'd workflow name and a workflow that genuinely didn't run look identical
  from here.
- **`PIPELINE_TIMEOUT=1`** → the watch ceiling elapsed before a terminal state;
  report the last state and offer to keep watching (re-launch with a longer
  `--timeout`).

In `--job` mode, report `PIPELINE_JOB_STATE` for the named job with the same
mapping (link `PIPELINE_JOB_URL`). A `none` here means no job by that name in the
pipeline yet — in one-shot that's "not created yet, earlier stages may still be
running"; in watch it means the appearance window elapsed without the job ever
showing (check the name, or the stage is gated). Mention the parent
`PIPELINE_STATE` only when it adds context (e.g. the pipeline failed elsewhere
while this job passed).

Name the workflow (`PIPELINE_WORKFLOW`) in the headline whenever the run is what
the verdict turns on — a failure, an in-flight state, or a `--workflow` the
caller asked for. On a plain pass the table's own Workflow column already says
it.

In watch mode the report *is* the notification — the harness surfaces it when
the background watch completes, so there's nothing to schedule or poll.
