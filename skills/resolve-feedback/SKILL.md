---
name: resolve-feedback
description: Fetch an open CR's review feedback and drive each thread to resolution — fix, reply, resolve. Use when addressing review feedback or resolving comment threads on an open PR/MR.
---

# Resolve Review Feedback

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

Bring unresolved review feedback into the author's branch, agree on the
response to every thread, and drive each chosen disposition to completion.

## Required phases

1. **Target:** read [setup](references/setup.md) and resolve the repo and CR.
   Preserve the enclosing task list when orchestrated.
2. **Fetch and triage (Steps 1–2):** read
   [fetch and triage](references/fetch-triage.md). Include unresolved human
   threads and top-level change requests. Stop when there is nothing to address.
   Present every thread and confirm its disposition with the author before
   acting. Triage approval approves actions, not the later reply wording.
3. **Act and report (Steps 3–4):** read [act and report](references/act-report.md)
   in full before editing or responding. Fix scoped code first, test, and commit
   through `anchor:commit`; then draft every reply and present its exact text
   for approval. Post only approved replies and resolve only the threads whose
   disposition and project conventions permit it. Do not resolve an unanswered
   question on the asker's behalf. Report fixes, replies, resolutions, deferred
   work, and what remains.
