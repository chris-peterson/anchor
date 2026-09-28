# Running a review

Every skill that asks the user to grade something runs the same loop: probe,
launch, wait, read the result, act on the verdict. This guide is that loop. Each
skill supplies what is its own: the `review-diff.sh` arguments, the
`editedFields` target its artifact comes back under, and what an `approved`
verdict leads to.

## Probe with the launch's arguments

Ask the dispatcher which mode and tool the review will open before launching:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" --skill <skill> --probe <the launch's subject arguments>
```

Give the probe the **same `--skill` and the same subject** the launch will get
(`--files <left> <right>`, a git range, `--local`). The mode follows the subject,
so a bare probe answers for a review nobody is about to open and names a tool
this one never will. Pass what it returned to the launch as `--mode
<REVIEW_MODE>`, so the review opens in the tool the probe found.

| Key | What to do with it |
| --- | --- |
| `REVIEW_AVAILABLE=0` | Nothing usable is installed: skip the launch and take the fallback ladder |
| `REVIEW_MODE=edit` | Name where the editor will appear. A GUI editor opens a window behind the terminal, and a review waiting in another window looks the same as one that never opened |
| `REVIEW_MODE_CONFIGURED` present | The run is opening a different shape than the preference named, because that one has nowhere to open. Name it |
| `REVIEW_MODE_SOURCE=subject` / `REVIEW_TOOL_SOURCE=default` | anchor picked that half, not the user. Add the configuration hint from `execute-quietly.md` under "when anchor picked the tool"; `REVIEW_TOOL` names the tool about to open |
| `REVIEW_EDIT_AVAILABLE=0\|1` | Whether the fallback ladder may offer the editor rung. Carry it forward |

## Launch in the background

Open the review through the dispatcher, not the tool directly: the dispatcher
builds the header and prints the normalized result. It blocks until the review
closes, so launch it as a **background** Bash call (`run_in_background: true`).
A foreground call holds the turn open until the Bash timeout.

The launch is quiet like every other step (`execute-quietly.md`), with the one
exception that guide makes for a review: **print the manifest as you launch**,
in its "show what is going under review" shape, with the probe facts above
folded in.

## While the review is open

The chat stays live while the tool is on screen, so feedback can arrive while
the user is partway through the review, writing into it. The open review stays
where it is: closing it from the chat side could throw away what they have
written in it.

When chat feedback arrives, reply with three things, then stop and wait:

1. **Acknowledge the feedback.** Restate it in a line, so the user can see it
   landed as they meant it.
2. **Say a review is still open.** Name the tool and where it is on screen (the
   tmux popup, the iTerm2 split, the editor window), since that is the thing
   they have to close.
3. **Say the flow is halted** until both are in: the feedback from chat and the
   open review's result.

> Got it: drop the retry flag from the usage block. Your revdiff review in the
> iTerm2 split is still open, so I've stopped here. When it closes I'll fold in
> both this and whatever you leave there, then open a second review.

Leave the files under review alone until the review closes. A difftool reports
the reviewer's edits against a snapshot taken at launch, so a change made from
the chat side reads back as something the reviewer wrote. More chat feedback
before the review closes gets the same short acknowledgement and joins the
pile.

When the review closes, apply both sets of feedback, then **open a second
review** of the revised changeset or draft, and proceed only on that review's
verdict. This holds whatever the first review returned: an `approved` with no
comments graded the version before the chat feedback, and the version that
would land is a different one.

## Read the result

When the background call completes, read its stdout with the **BashOutput
tool**, not `tail` or `$(...)`, which trip the command-substitution gate. The
last lines carry:

- `REVIEW_VERDICT`: `approved`, `changes-requested`, `incomplete`, or
  `no-verdict`.
- `REVIEW_OUTPUT`: compact JSON carrying `verdict`, `mode`, `tool`,
  `comments[]`, `editedFields[]`, `capabilities`, and `raw` (the DIFF contract in
  `SPEC.md`). Each comment is `{body, target, file?, startLine?, endLine?,
  side?}`, with `target` one of `line`, `file`, `changeset`, or the artifact's
  own target.

Only `approved` is approval. Comments are ungraded: every one is feedback to
address, and the verdict says whether it blocks.

| Verdict | Act on it |
| --- | --- |
| `approved` | Proceed to the skill's next step. Where `editedFields` carries the artifact's target, `edit` mode's saved buffer *is* the artifact: use that text verbatim, without re-drafting from it or re-presenting it for approval. Comments an approving review still left don't gate the step; surface them after it, and carry out one that asks for the follow-up itself (*file an issue for this*), through `/anchor:issue` where it asks for an issue |
| `changes-requested` | Nothing proceeds. Fold in every comment, echo them back in the review-feedback table from `execute-quietly.md`, and re-review. A comment whose `target` is `file` with a diff in its body is the reviewer's own edit rather than an annotation: read it per `reviewer-edits.md` |
| `incomplete` | The reviewer closed with changes unreviewed, a partial pass. Ask what they want to change, then re-review |
| `no-verdict` | The review did not complete. `capabilities.producesVerdict: false` means the tool graded nothing; otherwise it closed early or errored (see `raw.exitCode`). Say what happened in one line and take the fallback ladder. Don't silently retry: the same failure recurs |
| No verdict line at all | Empty stdout, stderr only, or no parseable `REVIEW_VERDICT`: the dispatcher exited before reporting. Treat it as `no-verdict`. Absent output looks like nothing went wrong, which is why it is never read as approval |

Never ask *"reviewed in your diff viewer, proceed?"* in place of a verdict. A
launched window is not evidence anything was read.

**Re-reviewing a drafted document**, after `changes-requested` or chat feedback,
compares against the previous draft rather than the original left-hand side.
Copy the draft aside before revising it, to a sibling path with `.prev` before
the extension, and pass that as the left. What the second pass has to show is
what the feedback changed.

## When the review didn't grade it

Nothing installed, `no-verdict`, and a missing verdict line all take the ladder
in `review-fallback.md`. A changeset takes the changeset rung; a drafted
document (a CR description, an issue body, release notes) takes the document
rungs.
