# Review qualities

What a review looks for. The `review` skill owns the *technique* — resolving the
CR, driving the diff viewer, placing each finding, gating the post — and this
file owns the *qualities*, so it's the place to edit as your preferences evolve.

Which qualities a review weighs follows your values, experience, role, and
domain. That is why they are written down here rather than left to whatever the
session happens to weight: add a quality, drop one, reword what a quality means,
rewrite the output instruction, and the next review follows the list as it
stands.

Each quality below is read against the diff **on its own**, by its own agent, so
one lens can't blur into another. A longer list is a wider review and costs
proportionally more.

## Analyze the changes for

- **Correctness**: Logic errors, edge cases, off-by-one errors, null/undefined
  handling: behavior a caller or a user would hit.
- **Style**: An inconsistency that will mislead the next reader, or that breaks a
  convention something depends on (a naming scheme a tool matches, a layout a
  generator reads). Not how you would have written it.
- **Security**: Obvious vulnerabilities, secret leaks, injection risks.
- **Simplicity**: Complexity that costs something now: a hidden bug, dead code
  that will be mistaken for live code, or an abstraction that is expensive to
  reverse once callers depend on it. Not code that could merely be shorter.
- **Documentation**: User-facing documentation the change leaves wrong or
  incomplete: a README, a guide, a help string, a usage example that no longer
  matches what the code does. Where the repo keeps a changelog, whether this
  change is recorded there the way its recent entries record theirs. A repo
  without one doesn't need one.

## Output

The description says what the author is trying to do. Treat it as the goal, not
a claim to audit: the intended change is not a defect. If the intent itself
looks mistaken, say so once, as a finding on the change as a whole.

A finding is one of two kinds:

- **Critical**: merging as written produces incorrect behavior, data loss, a
  security exposure, or a failed deploy. If you are unsure it clears that bar,
  it is a suggestion. Missing tests, error handling for states the code already
  prevents, naming, formatting, and consistency are never critical.
- **Suggestion**: a change that would alter what the author or a reviewer
  actually does. Preference, naming, and consistency with no functional
  consequence are not suggestions; leave them out.

Report only what you confirmed. If the surrounding code already prevents a
failure mode you considered, say nothing about it. "Might", "could", "appears
to", and "if X then Y" in a finding mean the check isn't finished: finish it and
state the result plainly, or drop it. A concern that rests on something you
can't confirm from the repository (a library's behavior, a runtime version, an
external service) is at most a suggestion, and says so.

Before reporting a fix, implement it in your head and ask whether you would now
raise something about the result. If so, fold that in and ask again, until the
fix is the one you would stand behind. A fix that would draw its own finding next
round is not finished.

There is no quota. No findings is the expected result on a small or simple
change, and a good one on any change; a list padded to look thorough costs the
reader more than it saves.

For each finding, give:

- critical or suggestion
- the file path and line (or say it concerns the file, or the change as a whole)
- the consequence: what goes wrong if it lands as written
- the evidence, in a clause: the file you read that confirms it, or the search
  that found no other caller
- the fix, in a sentence, and what it would touch: this line, this function,
  or callers and other files
