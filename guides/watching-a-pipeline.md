# Watching a pipeline

Every skill that starts CI, or waits on it, runs the same watch: launch it in
the background, carry on, read the verdict when it settles, report it in the
template's shape. This guide is that watch. Each skill supplies what is its own:
which helper it calls, the arguments (`--skill`, `--sha`, `--workflow`), and
where in its flow the report lands.

## Launch in the background

Both helpers block while they poll, so launch them as a **background** Bash call
(`run_in_background: true`). A foreground call holds the turn open until the
Bash timeout, and the flow the watch belongs to has already reported its own
result by then.

| Helper | Used for |
| --- | --- |
| `pipeline-after-push.sh --skill <skill>` | The pipeline a push or a merge just started (CI-13). It decides whether to watch at all: a config key can turn it off, and runs already reported are skipped (CI-14) |
| `pipeline-status.sh --watch` | Any other watch: `/anchor:pipeline`, a merge gate waiting on the CR's pipeline, a release run |

Pass `--sha` whenever the commit is not HEAD, such as a squash-merged commit or a
dispatched run on a commit you already pushed. A short sha is fine; the helper
resolves it to the full one.

## When a newer pipeline supersedes a running watch

A flow can start a second watch while an earlier one is still polling: a fix
pushed to the same branch, a merge landing the branch onto its target, a release
dispatched on the commit whose push is still being watched. The newer pipeline
is the one that says where the work stands, and two reports on one line of work
leave the user to work out which one counts.

So when you launch a watch on a newer pipeline for the same work, **stop the
older watch** (`TaskStop` on its background task) and report only the newer
one. Say so in the launch line, so the missing report isn't read as a pass:

> Stopped the watch on `a1b2c3d`; watching the pipeline for `e4f5a6b` instead.

A watch on another branch or another repo is not superseded by this one; leave
it running.

## Read the result

When the background call completes, read its stdout with the **BashOutput
tool**, not `tail` or `$(...)`, which trip the command-substitution gate.

- **`PIPELINE_WATCH=skipped`** (`pipeline-after-push.sh` only):
  `PIPELINE_WATCH_REASON` is `config-off` or `already-reported`. There is
  nothing to report; say nothing.
- **`PIPELINE_WATCH=ran`**, or any `pipeline-status.sh` output: report the
  `PIPELINE_*` lines following `templates/pipeline-report.md`, including its
  "After a push" notes where a push started the pipeline.
- **`PIPELINE_TIMEOUT=1`**: the watch ceiling elapsed before the pipeline
  settled. Report the last state and offer to keep watching with a longer
  `--timeout`. An unsettled pipeline never counts as passing.
- **`PIPELINE_STATE=none` under `--workflow`**: that workflow has no run for the
  commit. Check the name against the repo's workflow files before reporting a
  gap; a mistyped name and a workflow that never ran look the same from here.
