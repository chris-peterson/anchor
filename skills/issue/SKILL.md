---
name: issue
description: File a new forge issue (or update an existing one) that leads with WHY the work is needed. Use when filing, creating, drafting, or updating a single issue or ticket. To find, browse, or pick which issue to work on next, use the `backlog` skill instead.
---

# Issue

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

File or update an issue that leads with why the work is needed. Preserve the
project's template, actual labels and milestones, and the user's exact approved
wording. A plan or disposition approval is not approval of unpublished prose.

## Required phases

1. **Target:** read [setup](references/setup.md), then resolve the target even
   when it is a remote project with no local checkout.
2. **Intent and duplicates (Steps 1–3):** read [intent](references/intent.md).
   Distinguish create from update, capture an update baseline, resolve missing
   intent, and check for duplicates before drafting.
3. **Draft (Step 4):** read [draft](references/draft.md) and its template and
   prose guides. Apply the configured rules and verbosity without dropping
   required information.
4. **Metadata and presentation (Steps 5–6):** read
   [metadata and review](references/metadata-review.md). On updates, add metadata
   without replacing prior triage unless requested. Present the destination,
   exact title, body or update diff, labels, and milestone before asking for the
   disposition. Respect write, copy-only, edit, and cancel paths.
5. **Write only when approved:** read [write](references/write.md) before any
   create/update call. Use the correct forge invocation, report the result, and
   announce only the lifecycle event that actually occurred.
6. **If editing is requested:** read [revise](references/revise.md). Adopt saved
   issue-body edits verbatim; address every requested change and re-present.
   Incomplete or missing verdicts take the fallback ladder and never authorize
   filing. Return to the write phase only after the exact artifact is approved.
