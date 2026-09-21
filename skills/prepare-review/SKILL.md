---
name: prepare-review
description: Open the PR/MR on an already-pushed branch, rebase on the default branch if behind, and draft a description that tells reviewers WHY the change exists. Use when opening a PR/MR or creating a review.
---

# Prepare Review

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

Open or update a draft PR/MR on a pushed branch with a why-first description and
line-anchored review guide. Nothing is published until the exact title and body
have been presented and approved. Preserve the full procedure below, including
its no-forge, copy-only, existing-CR, and ungraded-review paths.

## Required phases

1. **Setup:** read [setup](references/setup.md) for purpose and output discipline.
2. **Gather (Step 1):** read [gather](references/gather.md) before the recon
   helper. Read [branch preparation](references/prepare-branch.md) before acting
   on branch/commit/push, reused-branch, or deletion-policy results. Read
   [rebase and state](references/rebase-state.md) before acting on behind/state
   results or reading the diff. All three files are required for Step 1;
   execute only the branches their results select. Retarget every command to
   the resolved repo. `NOTHING_TO_REVIEW` stops the flow and any dependent
   orchestration; do not silently proceed to merge or release. Where a commit
   or push is needed, hand off to `anchor:commit` and re-gather afterward.
3. **Resolve questions (Step 2):** read [questions](references/questions.md).
   Settle the why, ordering dependencies, and missing validation evidence before
   drafting. Do not invent answers or turn unresolved questions into prose.
4. **Draft (Step 3):** before writing, read all three:
   [template and config](references/draft-config.md),
   [content and formatting](references/draft-content.md), and
   [exclusions](references/draft-avoid.md), plus the required template/guides
   they name. Draft from the net changeset, apply the anti-recency check, honor
   the repo's template and verbosity, and build token-based deep-link
   placeholders rather than guessing line numbers.
5. **Review (Step 4):** read [checklist](references/review-checklist.md),
   [review procedure](references/review.md), and
   [fallback and write](references/write.md) before launching or interpreting
   review. Resolve placeholders and check the output before opening it. Preserve
   reviewer edits verbatim and re-review requested changes. Missing, incomplete,
   or unparseable verdicts never authorize a write; take the documented fallback
   and copy-only paths where applicable.
6. **Publish and finish (still Step 4):** after exact-text approval, follow the
   already-read write procedure for the selected forge, labels, and milestone.
   Then read [finish](references/finish.md) for the branch pipeline, captured
   ordering dependency, and lifecycle announcement. Announce only what this run
   actually created or updated and report the resulting CR URL.

Do not create a placeholder CR before the approval gate. Rebase/force-push
choices retain their own draft-state and user-approval guards from Step 1.
