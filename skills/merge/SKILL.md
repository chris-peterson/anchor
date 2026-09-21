---
name: merge
description: Merge an approved change request once its gates are green — waiting on the pipeline if needed — then clean up the branch. Use when merging or landing a PR/MR.
---

# Merge

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

Merge an approved change request after every gate passes, then clean up and
report the pipeline started by the merge. A green source-branch pipeline does
not establish the result of the merge's own pipeline.

## Required phases

1. **Target:** read [setup](references/setup.md) to resolve the repo, CR, and
   enclosing workflow.
2. **Gates (Step 1):** read [gates](references/gates.md) before evaluating
   readiness, conflicts, pipeline, approvals, and unresolved review threads.
   Follow the draft/ready choice and wait when CI is running. A failed or
   unsatisfied gate stops the merge; do not bypass it.
3. **Method and approval (Step 2):** read [method](references/method.md).
   Respect the repo's permitted merge methods and present the exact proposed
   merge for approval before acting.
4. **Merge and cleanup (Steps 3–4):** read
   [merge and cleanup](references/merge-cleanup.md). Use the forge-specific
   command, confirm what landed, announce the merge, and apply the documented
   local cleanup without discarding unrelated work.
5. **Pipeline and result (Steps 5–6):** read [report](references/report.md).
   Watch the actual merge commit, preserve its SHA even if local update fails,
   and report the outcome using the pipeline template and helper skip rules.
