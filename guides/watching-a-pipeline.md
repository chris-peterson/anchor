# Watching a pipeline

Every skill that starts CI, or waits on it, runs the same watch: launch it in
the background, carry on, read the verdict when it settles, report it in the
template's shape. This guide is that watch. Each skill supplies what is its own:
which helper it calls, the arguments (`--skill`, `--sha`, `--workflow`), and
where in its flow the report lands.

## Probe, then launch in the background

A watch is two calls with the same arguments:

1. **The probe, in the foreground.** It makes one read and announces
   `pipeline.watched` for sibling plugins (EVENTS-18). Output from a background
   call reaches no hook until the call ends, so the announcement has to come from
   this foreground step. The probe returns at once.
2. **The launch, in the background** (`run_in_background: true`). Both helpers
   block while they poll. A foreground call would hold the turn open until the
   Bash timeout, and by then the flow the watch belongs to has already reported
   its own result.

| Helper | Probe | Launch | Used for |
| --- | --- | --- | --- |
| `pipeline-after-push.sh` | `--skill <skill> --probe` | `--skill <skill>` | The pipeline a push or a merge just started (CI-13). It decides whether to watch at all: a config key can turn it off, and runs already reported are skipped (CI-14) |
| `pipeline-status.sh` | `--probe --skill <skill>` | `--watch` | Any other watch: `/anchor:pipeline`, a merge gate waiting on the CR's pipeline, a release run |

Read the probe before launching:

- **`PIPELINE_WATCH=skipped`** (`pipeline-after-push.sh` only):
  `PIPELINE_WATCH_REASON` is `config-off` or `already-reported`. Launch nothing
  and say nothing.
- **`PIPELINE_STATE=unreachable`**: the forge CLI failed. Report it as
  [Read the result](#read-the-result) says and launch nothing, since the watch
  would end the same way at once.
- **Anything else**: launch. Pass the probe's other arguments (`--sha`,
  `--workflow`, `--job`, `--repo`, `--single-run`) to the launch unchanged.

Once it is running, the watch announces `pipeline.updated` each time the
pipeline's state changes, and once early if a job fails while the pipeline is
still running (EVENTS-19). Those lines land in the watch's own output, ahead of
the `PIPELINE_*` verdict. They are for subscribers, not for the report.

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

- **`PIPELINE_WATCH=skipped`** (`pipeline-after-push.sh` only): the gates
  turned against the watch between the probe and the launch. There is nothing to
  report; say nothing.
- **`codes.bridgeai.anchor/pipeline.updated` lines** are announcements for
  sibling plugins. Leave them out of the report.
- **`PIPELINE_WATCH=ran`**, or any `pipeline-status.sh` output: report the
  `PIPELINE_*` lines following `templates/pipeline-report.md`, including its
  "After a push" notes where a push started the pipeline.
- **`PIPELINE_STATE=unreachable`**: the forge CLI failed, so nothing is known
  about the pipeline. Report `PIPELINE_ERROR` as it reads; on an auth error
  (401, 403, an expired token) ask the user to refresh the CLI's login and stop,
  without retrying. It never counts as passing, and never as "no pipeline".
- **`PIPELINE_TIMEOUT=1`**: the watch ceiling elapsed before the pipeline
  settled. Report the last state and offer to keep watching with a longer
  `--timeout`. An unsettled pipeline never counts as passing.
- **`PIPELINE_STATE=none` under `--workflow`**: that workflow has no run for the
  commit. Check the name against the repo's workflow files before reporting a
  gap; a mistyped name and a workflow that never ran look the same from here.
