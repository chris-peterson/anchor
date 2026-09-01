# When the review tool didn't grade it

A review reaches this guide from two places, and they are the same case:

- the probe said nothing usable is installed
  (`REVIEW_AVAILABLE=0`), or
- the review ran and came back `no-verdict`, `incomplete`, or with no parseable
  `REVIEW_VERDICT` at all — the tool closed early, died, or never launched.

Either way the change is **ungraded**, and nothing the review gates may
publish. What follows is the ladder down: each rung is a way to get a real
answer, not a way to get past the missing one.

## Say what happened, not where you are in this guide

The words on this page — *ladder*, *rung*, *descend*, *fallback* — are structure
for you, not vocabulary for the user. They locate a step against steps the user
never saw, so a reply built on them describes this document instead of their
change, and a user told they are on rung 2 has to ask what rung 1 was before
they can answer. Two sentences are owed: what the tool did, and what happens
next.

> The editor closed without saving, so nothing was published. Here's the draft.

not

> Since the editor was already the rung, here's the draft in chat.

Name the failure in the terms the user can see — the editor closed, the viewer
isn't installed, the pane went away — and then do the step.

## The question that is never on the ladder

> *You saw the diff — approve?*

The user may have read every hunk, or closed a window they never looked at, and
nothing distinguishes the two. A question that treats the launch as evidence
converts a tooling failure into an approval, which is the one outcome the
verdict contract exists to prevent. Ask about the **content**, never about the
window.

It is also why a difftool earns its verdict from the working tree rather than
from the screen (DIFF-18). Putting a diff in front of someone proves nothing; the
edits they leave in the files do, which is why a difftool is a tool here and a
mere viewer is not a rung.

## Rung 1 — hand over the artifact

Reached when the review was about a **drafted document**: a commit message, a CR
description, an issue body, release notes. Two things, both cheap, and neither
one waits on the other.

**Link the draft.** It is already a `.md` file under the temp dir
(`DESC_DRAFT_PATH` and its siblings, from `scripts/lib/tmpfile.sh`). Give the
path in your reply as a clickable link, so the user can open it in whatever
renders markdown properly. A fenced block in a terminal is not a rendered
document, and for anything with a table or a nested fence, the file is the only
honest way to read it.

**Offer the editor** when the probe reported `REVIEW_EDIT_AVAILABLE=1`. That
rung is a real review, not a consolation: the dispatcher opens the artifact in
the user's own editor with the change under review below a scissors line, and
whatever they save comes back through the contract as `editedFields`, adopted
verbatim (DIFF-13). For the skills that already default to it, this rung is
where they started, so a `no-verdict` from the editor lands on rung 2 instead of
being offered the same tool twice.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" --skill <skill> --tool editor …
```

`REVIEW_EDIT_AVAILABLE=0` means a launch would reach no editor — nothing
resolves along the chain (`core.editor`, `VISUAL`, `EDITOR`, a blocking VS Code
on `PATH`, git's compiled default, with a no-op `GIT_EDITOR` discounted per
DIFF-16), or there is nowhere to put one. Don't offer it, and don't launch it to
find out; say what would fix it if the user asks — `git config --global
core.editor '<your editor>'`.

## Rung 2 — walk it in chat

The floor, and the only rung that needs nothing installed. What it looks like
depends on what was under review.

**A drafted document** — put the full body in a fenced block in your reply.
Running a command that prints it shows the user nothing, for the reasons
[execute-quietly](/guides/execute-quietly) sets out. Then ask with
`AskUserQuestion`, header `Disposition`: write it · copy only · edit.

**A changeset** — walk the hunks. Not one question over a diff the user never
saw, and not a dump of `git diff` either: go file by file, and for each, say
what changed and why it changed, quoting the lines that carry the decision.
Invite feedback per file rather than once at the end. This is slower than a
viewer, which is the point — it is the rung where the reading actually happens
in the conversation, so the sign-off at the end rests on something.

Long changesets are where this gets skipped. Split it across replies rather than
compressing it into a summary: a summary the user approves is a review of your
summary.

## Don't retry into the same wall

A tool that failed to launch fails the same way on the next call. Say what
happened once, in one line — what the output showed, that nothing was published
— and go to the ladder. Re-running it reads as progress and produces the same
`no-verdict`.

The exception is a tool that was never tried: where the probe named a
substitute because the configured tool is absent, launching the substitute is a
first attempt, not a retry.

**`raw.exitCode: "unsaved"` and `"pane-closed"` are neither this case nor a step
here** — both are re-openable, and DIFF-14 treats them that way. The tool
worked. On `unsaved` the reviewer left the editor without writing, so the draft
went ungraded; saving is what approves it, unchanged included, and that is the
sentence they need. On `pane-closed` the terminal went away before the tool could
answer — a `⌘W` on the pane rather than a quit. Either way the draft is intact:
say which happened and open it again. Walking it in chat instead replaces
something their editor would have shown them properly.

## Naming the fix

Every rung here is a workaround for a machine with no diff viewer on it, and
that is worth saying once, without nagging. When the ladder was reached because
nothing is installed, close with the one-time cost rather than only the
degradation:

> No diff viewer installed — reviewing in chat. `revdiff` would give you inline
> comments and a real verdict.

Once per flow, at the end, and never in place of doing the rung.
