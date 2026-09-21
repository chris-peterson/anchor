## Run the helper

The helper detects the forge from the `origin` remote (`gh`/GitHub or
`glab`/GitLab), resolves the pipeline for HEAD's commit, and prints the verdict
on stdout. The forge plumbing — including the GitLab path's
`glab api projects/:fullpath/...` calls — lives in the script; the forge
cookbook's **CI / pipelines** section documents the same invocations.

**One-shot (default)** — runs and returns immediately, so call it in the
foreground and read the result:

```bash
bash "<anchor-root>/scripts/pipeline-status.sh"
```

**Watch** — add `--watch`. It blocks while it polls, so launch it with the host's
background/session mechanism and retain its handle; a foreground call would hold
the turn open until the command timeout. When it completes, read captured stdout
through that mechanism (not `tail` / `$(...)`, which trip the
command-substitution gate):

```bash
bash "<anchor-root>/scripts/pipeline-status.sh" --watch
```

To target a commit other than the current HEAD (e.g. an orchestrator that pushed
`main` directly), pass `--sha <sha>`, or `--branch <ref>` to take that ref's
commit — a tag works there too, and resolution is by commit either way. In watch
mode, poll cadence and the watch ceiling default to 15s / 30min and can be tuned
with `--interval <s>` / `--timeout <s>`.

**A GitHub commit has one run per workflow, not one pipeline.** The helper folds
them into a single verdict — each workflow's latest attempt, then the
least-settled and worst-off run speaks for the commit, so it reports in-flight
while any workflow is still going and red if any went red. When the ask is about
*one* workflow, name it with `--workflow <path|file|display name>`; the run that
answered is in `PIPELINE_WORKFLOW`. Naming it is what a release watch needs: the
run that a published release or a pushed tag fires carries the **tag** as its
branch, and it shares the commit with whatever the merge already ran, so
`--workflow <release workflow>` is how the verdict is about the release and not
a neighbor. On GitLab the flag has nothing to narrow — one pipeline per commit.

The fold is what *this* skill reports. `--single-run` opts out of it and reports
the commit's most recent run — what a caller wants when the forge's own merge
check already answers "is every check green" (`anchor:merge`'s gate does exactly
that).

**Track one named job** — when the ask is about a *specific* job rather than the
whole pipeline (*"wait for the `cand-usw2-plan` job,"* *"did the plan job
pass?"*), add `--job <name>`. It resolves the same pipeline, then reports or
watches just that job — so a one-off `glab api .../jobs | filter-by-name | poll`
loop becomes the same launch-and-read. `--watch` polls the job until it settles;
the match is the exact job name (retried jobs resolve to the latest attempt).
When you already have a pipeline id (e.g. from a URL the user pasted), pass
`--pipeline <id>` to skip commit→pipeline resolution:

```bash
bash "<anchor-root>/scripts/pipeline-status.sh" --job cand-usw2-plan --watch
bash "<anchor-root>/scripts/pipeline-status.sh" --pipeline 3435505 --job cand-usw2-plan
```

The output is `KEY=value` lines:

- `PIPELINE_STATE` — `success` · `failed` · `canceled` · `skipped` · `manual` ·
  `running` · `pending` · `none` (no pipeline for this commit) · `absent`
  (origin isn't a recognized forge). In watch mode, `PIPELINE_TIMEOUT=1` marks
  the last non-terminal state when the ceiling was hit.
- `PIPELINE_URL` — the pipeline's web page (link it).
- `PIPELINE_WORKFLOW` — on GitHub, the workflow whose run the verdict came from;
  empty on GitLab.
- `PIPELINE_RUNS` — every run for the commit with its jobs, in every state:
  `[{id, workflow, state, url, jobs: [{name, stage, state, url}]}]`. This is
  what the report tabulates; `PIPELINE_STATE` stays the headline. Absent when
  there's no pipeline (`none` / `absent`) and in `--job` mode, where the job
  lines below carry the detail instead.
- `PIPELINE_FAILED_JOBS` — present only when `PIPELINE_STATE=failed`: a JSON
  array of `{name, url}` (GitHub) or `{name, stage, url}` (GitLab), scoped to
  the run the verdict came from.

In `--job` mode the `PIPELINE_STATE`/`PIPELINE_URL` lines describe the parent
pipeline for context, and three more lines carry the tracked job:

- `PIPELINE_JOB_NAME` — the job name tracked.
- `PIPELINE_JOB_STATE` — normalized like `PIPELINE_STATE`; `none` means no job by
  that name exists in the pipeline yet (earlier stages may still be running).
- `PIPELINE_JOB_URL` — the job's web page (link it).
