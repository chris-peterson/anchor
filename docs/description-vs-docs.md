# Description vs. docs

Where does explanatory content belong — the CR description, or the repo's
docs? The two have different audiences and lifetimes: a description serves
*this review* and is rarely read after merge; repo docs serve every future
reader. anchor's skills consult this guide whenever the question comes up —
while drafting a description, prepping a commit, or addressing feedback.

## Default: description content belongs to the review

Review guides, validation evidence, context framing, before/after
comparisons of the change under review — these exist to route reviewer
attention and earn approval. They are review artifacts. Leaving them in the
description is correct, not a loss.

## Promotion is the exception, with a very high bar

Occasionally a description ends up carrying reference-grade material — a
mechanism walkthrough, a resolution sequence diagram, a per-field source
table — that documents *how the system works* rather than *what this change
is*. That content can be promoted into the repo's docs, but:

- **Only when the author flags it.** Don't promote on your own initiative;
  propose it at most, and only when the content plainly documents standing
  behavior rather than the change.
- **Adapt it for a long-lived home.** Strip review framing and drift-prone
  markers ("new", "previously", references to the MR itself); make it
  describe what *is*.
- **Fold it into whichever commit is already in flight** — the fix commit
  when addressing feedback, the branch's commit when prepping the CR. It
  needs no commit of its own.

## The drafting-time signal

If, while *writing* a description, an explanation grows into something a
future reader of the repo would need, that's the cheapest moment to split
it: put the reference content in the docs as part of the branch, and let
the description link to it.
