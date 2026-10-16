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

## Output

A finding earns its place when leaving the code as it is has a cost: a bug, a
security exposure, behavior the CR description doesn't match, or a decision that
is expensive to reverse once it lands (a public interface, a schema, a wire
format, persisted data). Stylistic preference, nits, and suggestions about
well-encapsulated code that is cheap to change later don't qualify. Returning no
findings is a complete answer.

For each finding, give:

- the file path and line (or say it concerns the file, or the change as a whole)
- the consequence: what goes wrong if it lands as written
- the fix, in a sentence, and what it would touch: this line, this function,
  or callers and other files
