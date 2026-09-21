---
name: pipeline
description: Report a commit's forge pipeline state, or watch until it settles. Use when checking the status of a pipeline, build, CI, or GitHub Actions run — or watching one to completion.
---

# Pipeline

Before using a bundled path, resolve `<anchor-root>` to the installed plugin root
from the host's value or this `SKILL.md` path. Read and follow
`<anchor-root>/guides/host-runtime.md`, including its instruction-reading rules.
Resolve the relative links below against this skill's directory.

The phase files are required instructions, not optional background. Before
executing a phase, read every file named for it in full; then follow its steps.
Read only the applicable phases, in order, and follow their stop conditions and
return paths. If a required read is missing or truncated, finish the read before
acting; never substitute this entry point's summary for the procedure. Retain
the resolved target and prior helper results across phases. After compaction,
re-read the current phase and recover those results before continuing.

Report a commit's pipeline state once, or watch it to a terminal state when
requested. GitHub workflow runs and GitLab pipelines share this flow.

## Required phases

1. **Target and mode:** read [setup](references/setup.md). Resolve the checkout
   on this invocation. Default to one-shot status; use watch for requests to
   wait or notify, and apply the unpushed-commit check before watching.
2. **Execute:** read [run](references/run.md). Pass the same target throughout.
   Run one-shot status in the foreground; use the host's background/session
   mechanism for watch and retain its handle. Interpret the helper's actual
   state, including no pipeline, instead of guessing from console text.
3. **Report:** read [report](references/report.md) and the pipeline report
   template. Include the relevant results and links, avoid duplicate reporting,
   and surface errors as prescribed. A watch must reach its documented outcome
   rather than being abandoned after it starts.
