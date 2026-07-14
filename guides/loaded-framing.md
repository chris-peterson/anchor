# Loaded framing

Reader-facing prose — commit messages, CR/MR descriptions, issue bodies, and any
doc or reply a human reads — should carry the facts and nothing else. Loaded
framing (blame, hyperbole, self-judgement, defensive softeners) adds noise that
prompts the reader to evaluate the *tone* instead of the *change*. The factual
claim usually survives the trim just fine, and reads cleaner for it. anchor's
prose skills consult this guide for the tone discipline — `commit`,
`create-review`, and `issue` all defer here.

## Patterns to cut

- **Temporal/historical blame.** Phrases that frame prior state as a fault:
  *"have always omitted X"*, *"has never worked"*, *"the old code was wrong"*.
  Drop the temporal frame; state what *is*.
  - Bad: *"The serializer has always omitted file and line attributes."*
  - Better: *"The serializer omits file and line attributes."*

- **Minimizing qualifiers about size.** Anything that leads with the change's
  small footprint, whether an adjective (*"one short block"*, *"a tiny fix"*,
  *"trivial change"*) or a count used as a framing device (*"one line, in …"*,
  *"just a one-liner"*, *"only N lines"*). Even on a genuinely small diff, lead
  with *where* the change is, not *how little* it is — the reader can see the
  diff, and being told it's small primes them to under-scrutinize.
  - Bad: *"The fix is one short block in `CreateTestCaseElement`."*
  - Better: *"This change adds a block in `CreateTestCaseElement`."*

- **Self-congratulatory adverbs.** Adverbs that judge your own code's
  correctness: *"correctly omits"*, *"properly handles"*, *"rightly returns"*.
  If the code is right, you don't need to say so; if it isn't, the adverb won't
  save it.
  - Bad: *"The logger correctly omits the attributes when source is empty."*
  - Better: *"The logger omits the attributes when source is empty."*

- **Defensive softeners on technical claims.** Adverbs that pre-empt pushback by
  emphasizing safety: *"purely additive"*, *"completely backward-compatible"*,
  *"totally safe"*. The qualifier signals you're defending against an objection,
  which invites the reader to go look for it.
  - Bad: *"The change is purely additive."*
  - Better: *"The change is additive."*

## Exceptions

- Load-bearing claims where the qualifier is the point — *"passwords are never
  logged"* is a security guarantee, not hyperbole.
- Explicit deprecation notices, where naming the prior state is the announcement.
- Internal scratch documents where tone-checking isn't the goal.
