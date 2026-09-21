---
name: review
description: Review an open change request — read every change in the diff viewer, examine it against the qualities you've set, then post the findings as inline threads once the exact text is approved. On your own CR it runs as a self-review instead — the fixes land in the tree, nothing posts, and it ends by offering to mark the CR ready. Use when reviewing a PR/MR, when a teammate sends a CR number or URL, or when reviewing your own change before handing it over.
---

# Review

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

Review an open CR by reading its description and every change, then examining
the diff against every configured quality. Authorship decides where findings go:
another author's CR gets approved comment text; the user's own CR gets a local
fix list by default. Never approve or request changes as a forge review state.

## Required phases

1. **Setup:** read [setup](references/setup.md) for modes and output discipline.
2. **Resolve and understand (Steps 1–2):** read
   [resolve and read](references/resolve-read.md). Resolve the CR's forge and
   head, check its state and authorship, and read its description before the
   diff. Clarify missing intent rather than inventing it.
3. **View every change (Step 3):** read [view](references/view.md). Use the
   dispatcher and full range; handle unavailable/ungraded review through its
   fallback. An opened window is not evidence that every change was read.
4. **Examine (Step 4):** read [examine](references/examine.md) and the review
   qualities template. Follow its independent quality passes, combine all
   findings and annotations, and prepare the exact preview.
5. **Own CR (Step 5):** when `IS_OWN_CR=1`, read
   [self-review](references/self-review.md). Agree the fix list, make scoped
   changes, commit through `anchor:commit`, and re-review the fresh head.
   Leave it draft unless the user chooses a ready/reviewer handoff. Do not post
   findings unless the author explicitly chooses the thread-posting path.
6. **Other CR or explicitly chosen threads (Steps 6–7):** read
   [post and report](references/post-report.md). Present and get approval of
   the exact text before posting; use the correct forge's thread/batch behavior.
   Edits return to preview and approval, not directly to publication.
7. **Report (Step 8):** use the reporting section of
   [post and report](references/post-report.md) after either route; do not run
   its posting steps on a self-review route that did not select them.
