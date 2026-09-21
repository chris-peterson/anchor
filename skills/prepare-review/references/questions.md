## Step 2: Resolve open questions before drafting

The description needs the author's motivation **and any decisions still in flux**. If something would otherwise come out of the description as a hedge or an open offer ("happy to bump version if you'd like", "open to adding a test", "could split this into two CRs"), it's a question — ask it now, then draft. **The CR description is not a place to negotiate.** Any ambiguity is a reason to *defer* drafting, not park inside it.

Before drafting, scan for these common ambiguities and ask the user about each one that applies:

- **Why** — what problem this solves and why it matters (the prompt below)
- **Audience / threat model** — for security or visibility changes, *who* is the affected population? "Anyone who can read X" is too vague. Name the population concretely: anyone inside the network, anyone with read access to the source, the on-call team, etc.
- **Scope decisions** — should this be split? Squashed? Feature-gated? Released alongside something else?
- **Ordering dependency** — must this CR land *after* another one (a shared library before its consumer, a config that points at the consumer)? Don't infer this aggressively — take it when the user says so, or when they've had you open the CRs as an ordered chain this session. If so, capture the predecessor CR (its iid/number, and project when cross-repo); Step 3 records it in the description and Step 4 sets the forge dependency.
- **Surface decisions** — version bump, deprecation timeline, migration guidance for downstream callers
- **Verification gaps** — anything you can't actually test from the working environment (UI, downstream consumers, prod-only behaviors). Surface these to the author so they can plan how/when to verify before merge. These are author homework — they do **not** become checklist items in the description.

Wait for answers to all of them before drafting. A description shipped with parked questions is worse than one shipped a turn later.

If the only open item is the WHY, ask:

> **What problem does this solve, and why does it matter?**
>
> The diff shows *what* changed — I need you to tell me *why*. A sentence or two is enough. For example:
> - "Users were getting 500 errors when their session expired mid-checkout"
> - "We need to support the new billing API before the March deadline"
> - "The old approach couldn't scale past 10k concurrent connections"

**Draft the WHY only from what you were actually given — the author's answer, the diff, or a cited doc. A correct-but-narrow WHY always beats a speculative-but-broad one.** When the WHY comes in thin, that thinness is the signal to *ask* (or confirm your reading) — not to fill. Don't elaborate the motivation past the source, and don't invent *supporting* detail to prop it up: not a surrounding narrative (a single named artifact — a script, a job — is not evidence of a category or a recurring practice), and not technical mechanics the author never stated, however plausible. A thin, sourced WHY ships; a rich, invented one is the "invented current state" failure (Step 3, "What to avoid").
