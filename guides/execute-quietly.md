# Execute quietly

The value of a skill is a fast, consistent workflow. Prose the user has to read
works against that, so silence is the default: output is the exception, reserved
for the points where the user must act or decide.

## Delegating to a script is silent by default

The helper scripts a skill launches — `squash-check.sh`, `look-ahead.sh`,
`prepare-review.sh`, `pipeline-status.sh`, `review-diff.sh`, the project's test
runner — exist to do the deterministic work *for* you. Their `KEY=value` output
is the **input to your next decision**, not something to report. Launch the
script, read its output, act on it — without narrating that you did, and without
relaying the state it surfaced.

## Show the finished artifact, keep the intermediates quiet

Silence covers the *intermediate* objects: the `KEY=value` blocks, the gate
outcomes, the diff you ran to check your own work. The finished artifact is the
opposite. The commit message, the CR description, the drafted issue are what the
user is there to decide on, and they have to actually reach the user — as text
in your reply, or through a review tool that shows them properly.

Running a command shows the user nothing. A Bash tool's output goes to *you*;
the terminal collapses it to a `+80 lines (ctrl+o to expand)` stub. So a command
whose whole purpose is to present something (`git diff --no-index` of a drafted
description against the live one, a rendered table) satisfies nothing on its
own.

The failure this catches is a confirmation prompt about content the user never
saw: the artifact "presented" as a collapsed tool result, then *Write this to the
PR?*

## Don't narrate the reasoning that led to an action

A decision is output; the derivation behind it is not. The tell is a sentence
that explains *why* before it shows *what*, chaining internal facts toward a
conclusion:

> *"No `anchor.*` config, squash gate closed, so this is an ordinary commit —
> but HEAD is `main`, so a feature branch first."*

Four internal facts marshalled to justify two choices. Present the drafted
message and the branch options and nothing else — the choice is the output, not
the reasoning that produced it. The same goes for the config keys you read, the
gate outcomes, the orchestration check, the test-runner you discovered, and any
*"docs-only, but I'll confirm it's green"* hedge: all internal.

## What *is* output

Speak only when the user must act or decide — a question you need answered, a
failing check, the drafted artifact with its options, the final verdict — and
where a step prescribes exact output (e.g. `Committed [short-sha]`), emit that
and nothing more. The user reads decisions and results, never the derivation
behind them.

## Exception: show what is going under review

A review asks the user to grade something, and the tool draws it one file — or
one buffer — at a time. The *set* is what it never shows: which files are in
scope, how much each one moved, which repo and branch they belong to, and what
rides alongside them. So print that manifest as a table in the message that
launches the review, and let the tool render the contents.

> Opening the review in a split — revdiff, `chris-peterson/anchor` on `main`,
> with the drafted commit message:
>
> | File | Change |
> |------|--------|
> | `scripts/lib/split-run.sh` | +45 −29 |
> | `tests/split-run.test.sh` | +76, new file |
> | `SPEC.md` | +18 −15 |

Name the drafted artifact riding with the diff — the commit message, the CR
description, the release notes — because the backend shows it in a pane or a
header the user has no reason to look for.

### When anchor picked the tool, say which key would pick it instead

The probe reports where each half of the choice came from —
`REVIEW_BACKEND_SOURCE` and, for an editor review, `REVIEW_EDITOR_SOURCE`. On
`default`, anchor coalesced onto something rather than opening what the user
asked for, and the tool itself is the last place that would ever mention it. Add
one line under the table naming the key, and the value that would have produced
what they're looking at:

> Both picked by anchor — `git config anchor.prepare-review.reviewBackend
> <editor|revdiff>` chooses the shape, `git config --global core.editor
> <editor>` the editor.

Only for the half that says `default`; a choice the user typed needs no hint,
which is what retires the line once they've made one. Say it in the launch
message and nowhere else — this is a hint sitting next to the thing it's about,
not advice to lead with.

The manifest is the launch's half of the loop that "echo back feedback" closes:
the user grades a scope you named, and you repeat back what they said about it.
The rest of the launch stays silent — the command, its flags, the backend
resolution, the wait.

## Exception: echo back feedback from a review tool

The one input you *do* surface verbatim is feedback that reached you through a
review/diff tool's side channel — revdiff's annotations, or any equivalent.
The user typed those comments outside the chat and has no confirmation you
received them, so close the loop before acting: echo the comments back in a
table under a **Review feedback** heading, then say what you're about to do
about them.

> **Review feedback:**
>
> | # | Where | Comment | Action |
> |---|-------|---------|--------|
> | 1 | `pricing.js:42` | "DAILY_MAX is defined here and in fare.js — use one source" | fix + amend |
> | 2 | changeset | "why not Fargate for this?" | reply, no code change |
>
> Now: pulling `DAILY_MAX` from one module, then re-running the review.

This covers only the human comments the verdict carried — *how* you obtained the
verdict (launching the tool, reading its output) stays silent under "Delegating
to a script is silent by default." Echoing received feedback is closing a loop
the user opened; narrating the plumbing that fetched it is not.
