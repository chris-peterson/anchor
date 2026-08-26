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
  handling.
- **Style**: Consistency with the rest of the codebase.
- **Security**: Obvious vulnerabilities, secret leaks, injection risks.
- **Simplicity**: Unnecessary complexity, over-engineering, dead code.

## Output

Output your review as a numbered list of findings. Be direct and specific.
Reference file paths and line numbers. If the CR looks good, say so briefly —
don't manufacture issues.
