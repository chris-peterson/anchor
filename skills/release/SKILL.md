---
name: release
description: Cut a release for what has landed — recommend a semver bump, draft the notes, and drive the repo's own publish path. Use when releasing, publishing, cutting a version, or shipping a new version.
---

# Release

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

Release what has landed using the repository's own versioning and publishing
model. Repository instructions outrank inferred triggers. Preserve exact-text
approval of release notes and confirmation of the publishing action.

## Required phases

1. **Target:** read [setup](references/setup.md) and resolve the repo and any
   enclosing workflow.
2. **Recon (Step 1):** read [recon](references/recon.md) before running the
   helper. Read any named publishing docs and the matching release-model guide
   section. Stop for no version artifact or no new commits as documented;
   surface dirty or unpushed state before continuing. Do not substitute a model
   when the repo specifies a publishing path Anchor does not cover.
3. **Range, version, and notes (Steps 2–4):** read [draft](references/draft.md).
   Read the landed range, recommend the version, and draft complete user-facing
   notes with the configured verbosity. The final part of this file introduces
   Step 5 and determines where the notes must be reviewed.
4. **Publish (Step 5):** read only the selected procedure in full before acting:
   - `release-triggered` or `tag-triggered`: [published body](references/publish-body.md).
     Review the notes as an artifact; incomplete or missing verdicts never
     authorize publishing. Follow the distinct release/tag trigger instructions.
   - `dispatch-triggered`: [dispatch](references/dispatch.md). Commit the reviewed
     notes through `anchor:commit`, then dispatch the owning workflow.
   - `bump-commit`: [bump commit](references/bump-commit.md). Make the prescribed
     bookkeeping change and send its exact diff/message through `anchor:commit`.
   The workflow owns version bumps on CI-owned models. Never add a second bump,
   create an unrequested release/tag, or bypass the selected model's gates.
5. **Verify and report (Step 6):** read [report](references/report.md). Read back
   the published outcome and announce only a release that actually exists.

Respect the reviewer's saved notes verbatim and re-review requested changes.
A rejected push or failed publishing step is not a successful release.
