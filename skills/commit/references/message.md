## Step 3: Write the commit message

Write the message following the format in `<anchor-root>/templates/commit-message.md` — it owns the *shape* (the [cbea.ms](https://cbea.ms/git-commit/) rules and the trailer). Spend your effort on the *why*; the code already shows the *how*. If the change is trivial (typo fix, one-liner), a subject-only message is fine.

Keep the body free of loaded framing — temporal blame, size-minimizers, self-congratulatory adverbs, defensive softeners. The tone discipline lives in `<anchor-root>/guides/loaded-framing.md` (shared with `prepare-review` and `issue`); consult it while drafting.

### Honor `anchor.*` config

`ANCHOR_CONFIG` from Step 1's block holds the `anchor.*` keys as JSON (`{}` when none); the names come back lowercased (`anchor.worktrackerbaseuri`) — match case-insensitively. Apply the keys relevant to a commit; absent keys keep `anchor`'s defaults — never invent a value:

- **`anchor.workTrackerBaseUri`** — when the user mentions a ticket (a full tracker URL, or a bare id), append a `Refs:` trailer (a footer line after a blank line, below the body): use a full URL as-is, or build `<base-uri><id>` from a bare id. Don't scrape the branch or prompt for a ticket — no mention, no trailer. Skip it for a trivial subject-only commit unless the user asks.
- **`anchor.commitRules`** — an extra rule layered onto the default commit-message rules for this message (the escape hatch for anything without a dedicated key).
- **`anchor.commitVerbosity`** — an integer 1–100 setting where the message *body* sits between brevity and thoroughness. **Unset behaves as `50`**: the why, plus the context the diff doesn't carry. **It is not a word budget** — nothing is counted or truncated, and two changesets at the same setting run to different lengths. Clamp an out-of-range or non-integer value into the 1–100 band and say so once rather than failing the draft.

  Apply it to the body alone. **The subject line is not on the dial** — its format rules (imperative, ≤50 chars, no trailing period) are the template's and hold at every setting, and so does the `Refs:` trailer. Work down this order and stop where the draft balances where the setting asks: asides and the clause qualifying a claim nobody disputes → the decisions-and-alternatives prose, down to the decision itself → the context paragraph, down to its *why* sentence. The floor is one sentence of why; a trivial change still earns the subject-only message the template allows, which is a judgment about the change, not a verbosity setting.

See `<anchor-root>/guides/configuring.md` for the full key set.

Write the drafted message to a temp file (`$(mktemp -u /tmp/commit-msg.XXXXXX).md`)
with the host's file-writing mechanism — the literal `/tmp` is what a caller's
path-scoped write grant reaches (`<anchor-root>/guides/temp-paths.md`). Step 5
passes it into the review so you review the message alongside the diff, and
Step 6 commits it (or the reviewer's edited version).
