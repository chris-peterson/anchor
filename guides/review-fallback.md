# When the review tool didn't grade it

A review reaches this guide from two places, and they are the same case:

- the probe said nothing usable is installed
  (`REVIEW_AVAILABLE=0`), or
- the review ran and came back `no-verdict`, `incomplete`, or with no parseable
  `REVIEW_VERDICT` at all — the tool closed early, died, or never launched.

Either way the change is **ungraded**, and nothing the review gates may
publish. What follows is the ladder down: each rung is a way to get a real
answer, not a way to get past the missing one.

## The question that is never on the ladder

> *You saw the diff — approve?*

The user may have read every hunk, or closed a window they never looked at, and
nothing distinguishes the two. A question that treats the launch as evidence
converts a tooling failure into an approval, which is the one outcome the
verdict contract exists to prevent. Ask about the **content**, never about the
window.

This is why a difftool is not a rung, and not a tool either (DIFF-18). It can
put a diff on screen, but it speaks no contract, so its review ends here
regardless — one screen later, with the user primed to say yes.

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

**`raw.exitCode: "pane-closed"` is not this case, and not a rung.** The tool
works; its terminal went away before it could answer — a `⌘W` on the pane
instead of a quit from the editor's own menu. Say that, say the draft is
intact, and offer to open it again. Descending the ladder here hands the user a
chat walkthrough of something their editor would have shown them properly.

## Naming the fix

Every rung here is a workaround for a machine with no diff viewer on it, and
that is worth saying once, without nagging. When the ladder was reached because
nothing is installed, close with the one-time cost rather than only the
degradation:

> No diff viewer installed — reviewing in chat. `revdiff` would give you inline
> comments and a real verdict.

Once per flow, at the end, and never in place of doing the rung.
