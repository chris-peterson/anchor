# Execute quietly

The value of a skill is a fast, consistent workflow. Prose the user has to read
works against that, so silence is the default: output is the exception, reserved
for the points where the user must act or decide.

## Delegating to a script is silent by default

The helper scripts a skill launches — `squash-check.sh`, `look-ahead.sh`,
`create-review.sh`, `pipeline-status.sh`, `review-diff.sh`, the project's test
runner — exist to do the deterministic work *for* you. Their `KEY=value` output
is the **input to your next decision**, not something to report. Launch the
script, read its output, act on it — without narrating that you did, and without
relaying the state it surfaced.

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

## Exception: echo back feedback from a review tool

The one input you *do* surface verbatim is feedback that reached you through a
review/diff tool's side channel — moor's sidecar verdict, or any equivalent.
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
