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
| `REVIEW_PRELOADS=0` | The tool can't show preloaded notes. A review given `--explain` opens without them, so put them in the manifest, one line each with its `file:line` |
| `REVIEW_HOST` | Open the manifest with one line saying where the review is, so a user who comes back to this pane later knows where to look: 👀 *the review is open in an iTerm2 split of this pane* (`iterm2`), *in a tmux popup over this pane* (`tmux`), *in an agterm overlay over this session* (`agterm`), *in an editor window, possibly behind this one* (`gui`), *wherever your `ANCHOR_HOST_RUNNER` puts it* (`launcher`) |

## Put each note where the reader is already looking

A review the skill seeds with notes (a round's findings, a reply, a batch, the
agent's notes on its own changes per [review-notes.md](review-notes.md)) puts
each note on a line: the changed line it is about, or the line the reviewer's
own comment sat on. That is where the reviewer's eyes are when they reach it,
and a note there reads like a comment in any code review. A note on the whole
file, or a row in `(context).md`, sends them off to find the code it means.

| The note is about | It goes |
| --- | --- |
| a change | on its first changed line; its other sites are named in that note |
| something the reviewer asked | on the line they asked it on, unless the answer is a change |
| a file as a whole: added, deleted, or renamed with nothing to point at | on the file |
| the resource a file stands for in a batch: an issue, a CR, a thread reply | on the file |
| the commit message, the description, or the changeset as a whole | in the `(context).md` table |

A file-level note on a file with changed lines is almost always a line note
that lost its line. Find the line.

Place each note where it belongs and let the scripts deliver it. A reviewer
stepping through revdiff with `]` goes hunk to hunk, so while that holds the
scripts adjust: a note within a few lines of a change stays put, since it is on
screen when `]` lands there; a note on a whole file moves onto that file's first
change, opening with *↪ about the whole file*; and a note far from every change
goes into `(context).md` with the lines it concerns quoted, rather than onto
code it isn't about.

A line in a file the review leaves out, because nothing in it changed, has
nowhere in the diff to sit: revdiff would open that file in full. A reply round
handles this itself, answering in `(context).md` with the lines quoted.

## Launch in the background

Open the review through the dispatcher, not the tool directly: the dispatcher
builds the header and prints the normalized result. It blocks until the review
closes, so launch it as a **background** Bash call (`run_in_background: true`).
A foreground call holds the turn open until the Bash timeout.

**The launch ends the turn.** Ask every question the flow needs answered before
the review (the branch, the squash, anything else) and have the answer in hand
before you launch. Once the review is open, ask nothing through
`AskUserQuestion`: an open question holds the turn, and the background call's
completion can't reach the session until it is answered, so the verdict waits
behind it and the reviewer's comments look ignored.

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

A request to stop showing the keys a review lists ("hide hints", "hide diff
hints", "dismiss the hints") isn't feedback on the change: run
`git config --global anchor.hints false`, say so in a line, and leave the
review open. A request naming one mode ("hide the revdiff hints") sets that
mode's key, `anchor.diff.hints` or `anchor.edit.hints`, instead.

When the review closes, apply both sets of feedback, then **open a second
review** of the revised changeset or draft, and proceed only on that review's
verdict. This holds whatever the first review returned: an `approved` with no
comments graded the version before the chat feedback, and the version that
would land is a different one.

## Read the result

When the background call completes, read its stdout with the **BashOutput
tool**, not `tail` or `$(...)`, which trip the command-substitution gate. The
last lines carry:

- `REVIEW_VERDICT`: `approved`, `changes-requested`, `rejected`,
  `incomplete`, or `no-verdict`.
- `REVIEW_OUTPUT`: compact JSON carrying `verdict`, `mode`, `tool`,
  `comments[]`, `editedFields[]`, `capabilities`, and `raw` (the DIFF contract in
  `SPEC.md`). Each comment is `{body, target, file?, startLine?, endLine?,
  side?}`, with `target` one of `line`, `file`, `changeset`, or the artifact's
  own target.

Only `approved` is approval. Comments are ungraded: every one is feedback to
address, and the verdict says whether it blocks.

| Verdict | Act on it |
| --- | --- |
| `approved` | Proceed to the skill's next step. A comment with `target` `verdict` is the note the reviewer chose Accept with (on the Accept line, or a lone `lgtm` anywhere): relay it only where it says more than the choice. Where `editedFields` carries the artifact's target, that text *is* the artifact (`edit` mode's saved buffer, or the draft as saved before an edit review was switched to the viewer): use it verbatim, without re-drafting from it or re-presenting it for approval. Comments an approving review still left don't gate the step; surface them after it, and carry out one that asks for the follow-up itself (*file an issue for this*), through `/anchor:issue` where it asks for an issue |
| `changes-requested` | Nothing proceeds. Fold in every comment, into the `editedFields` text where it carries the artifact's target (the reviewer edited the draft before switching to the viewer) and into the draft otherwise, echo them back in the review-feedback table from `execute-quietly.md`, and re-review (a changeset as a reply, below). A comment whose `target` is `file` with a diff in its body is the reviewer's own edit rather than an annotation: read it per `reviewer-edits.md` |
| `rejected` | The reviewer chose Reject. Nothing the review gates happens, and nothing falls back: say it stopped, with no error banner, and relay any note they left (`comments` with `target` `verdict` carry the note they chose with). Don't redraft or reopen unless they ask |
| `incomplete` | The reviewer closed with changes unreviewed, a partial pass. Ask what they want to change, then re-review |
| `no-verdict` with `raw.exitCode` `undecided` | The reviewer quit without choosing: revdiff with no note on Accept or Reject (or one on both), or an editor without saving. Ask with `AskUserQuestion`: Accept, Reject, or Reopen the review, and act on the answer as that verdict (Reopen launches the same review again). An answer typed in place of the three is the change they want: fold it in as `changes-requested`. This is the one question a review's result is allowed to lead to, because the reviewer read it and closed it without saying which |
| `no-verdict` | The review did not complete. `capabilities.producesVerdict: false` means the tool graded nothing; otherwise it closed early or errored (see `raw.exitCode`; `unsaved`, a GUI editor that returned without waiting, and `pane-closed` reopen rather than fall back, per `review-fallback.md`). Take the fallback ladder, opening and closing the reply with its error banner. Don't silently retry: the same failure recurs |
| No verdict line at all | Empty stdout, stderr only, or no parseable `REVIEW_VERDICT`: the dispatcher exited before reporting. Treat it as `no-verdict`. Absent output looks like nothing went wrong, which is why it is never read as approval |

Never ask *"reviewed in your diff viewer, proceed?"* in place of a verdict. A
launched window is not evidence anything was read. `undecided` is the
exception above, and its question offers all three answers rather than
proceeding by default.

**Re-reviewing a drafted document**, after `changes-requested` or chat feedback,
compares against the previous draft rather than the original left-hand side.
Copy the draft aside before revising it, to a sibling path with `.prev` before
the extension, and pass that as the left. What the second pass has to show is
what the feedback changed.

**Re-reviewing a changeset is a reply.** A `--local` review that returns
`changes-requested` prints `REVIEW_STATE=<dir>`: the changeset as the reviewer
closed it, and the comments they left. The next review shows only what you
changed after that, with your answer to each comment in the diff, so the
reviewer doesn't have to hunt the chat for answers or reread the whole change
to find yours. Once the fixes are in and the tests pass:

1. **Answer every comment** in a replies file
   (`$(mktemp -u /tmp/review-replies.XXXXXX).json`), by its position in
   `comments[]`, starting at 1. The shape is in `scripts/review-reply.sh`'s
   header. Each reply says what became of the comment, which is what the
   reviewer can't tell from the diff alone:

   | `status` | When | `reply` |
   | --- | --- | --- |
   | `answered` | a question; nothing to change | the answer |
   | `done` | you made the change it asked for | what you changed, in a line |
   | `different` | you changed something else, or nothing | what you did instead, and why |

   Give `sites` (the lines the reply is about, as the tree now stands, each
   with its `line`) for a change; leave them out for an answer, and it sits
   under the line the comment was on. A comment on the commit message or the
   whole changeset is answered in the `(context).md` table. Placement follows
   "Put each note where the reader is already looking", above.
2. **Seed it** with the `--path` list the review will get:
   `review-reply.sh --state <REVIEW_STATE> --replies <file> --path <p>...`. A
   `REPLY_ERROR` line names a comment with no reply, or a site revdiff can't
   show; fix the file and seed again.
3. **Re-open the review with `--reply <REVIEW_STATE>` added**, its
   `--message-file` and `--path` list unchanged.

Each reply opens with *You asked:* and the comment, and `(context).md` opens
with a table of every comment and what became of it. A reply the reviewer
leaves as it is, or deletes, is read. One they edit, or a new note, is feedback,
and the verdict says which. Another `changes-requested` prints the next
`REVIEW_STATE`, holding only that feedback. A review with no `REVIEW_STATE` (a
`--staged-path` commit, or a viewer that can't preload notes) re-reviews the
whole changeset.

## When the review didn't grade it

Nothing installed, `no-verdict`, and a missing verdict line all take the ladder
in `review-fallback.md`. A changeset takes the changeset rung; a drafted
document (a CR description, an issue body, release notes) takes the document
rungs.
