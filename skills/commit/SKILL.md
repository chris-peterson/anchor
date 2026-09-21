---
name: commit
description: Stage changes, run tests, review the diff and drafted commit message with the user, then commit and push once they approve. Use when work is ready to commit or push; the diff review is a step of this skill, so don't offer to show the changes as a separate step beforehand.
---

# Commit and Push

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

Stage the session's changes, test, draft the message, review the exact changeset
and message, then commit, push, and report the pipeline.

## Required phases

1. **Resolve the target and orchestration:** read [setup](references/setup.md).
   Re-resolve the checkout on each invocation; preserve any enclosing task list.
2. **Stage and test (Steps 1–2):** read [stage and test](references/stage-test.md)
   before the first recon command. Name only the session's paths. Preserve the
   same path list through staging, review, and commit, leaving others' staged
   work alone. Stop when there is nothing to commit or push. With no staged
   changes but unpushed commits, follow the push-existing route directly to
   review; do not run tests or draft a new message for that route.
3. **Draft (Step 3):** read [message](references/message.md), including its
   template and applicable configuration. The exact message goes into review,
   not a separate chat approval.
4. **Choose branch and shape (Step 4):** read [shape](references/shape.md).
   Protect the default branch and apply the helper's squash gate. Ask only the
   branch/shape choices prescribed there. The message-only-amend exception is
   narrow: an unchanged tree, the helper's permission, and explicit approval of
   the corrected message and force-push; it is not permission to rewrite code.
5. **Review (Step 5):** read [review](references/review.md). Use the dispatcher
   and retain its background handle. Review the exact scoped diff and message
   together; push-existing reviews the commit range. Apply the reviewer's saved
   message verbatim. Changes requested return through fixes, tests, drafting as
   needed, and re-review. Incomplete, absent, or unparseable verdicts never
   authorize a commit; follow the documented fallback.
6. **Commit, push, and watch (Steps 6–7):** read
   [publish](references/publish.md) before executing the approved shape.
   Commit exactly the reviewed paths and message. Report push failures and stop;
   do not invent a force-push retry. After a successful push, run the pipeline
   helper and report its result, respecting its skip decision.

On a pre-tool hook rejection, read [hook failure](references/hook-failure.md)
before responding or retrying. Approval applies to the exact artifact reviewed;
a launched review window or silence is never approval. Surface approved review
comments and carry out explicitly requested follow-ups as the review phase says.
