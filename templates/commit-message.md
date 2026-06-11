# Commit message template

The shape of a commit message. The `commit` skill owns the *technique* — when to
squash vs. new-commit, the test gate, the visual-diff review. This file owns the
*shape*, so it's the place to edit as your preferences evolve.

## Format

Follow the seven rules from [cbea.ms/git-commit](https://cbea.ms/git-commit/):

1. **Separate subject from body with a blank line**
2. **Limit the subject line to 50 characters** — hard limit 72
3. **Capitalize the subject line**
4. **Do not end the subject line with a period**
5. **Use the imperative mood** — "Add feature" not "Added feature". Test: "If applied, this commit will _[subject line]_"
6. **Wrap the body at 72 characters**
7. **Use the body to explain what and why, not how**

Focus on the *why* — the code already shows the *how*. If the change is trivial
(typo fix, one-liner), a subject-only message is fine.

```text
Subject line here

Body paragraph explaining why this change was made, wrapped at 72
characters. Focus on context that isn't obvious from the diff.

Refs: https://app.clickup.com/t/8a1b2c3d
```

## Trailers

A trailer is a `Key: value` footer line, set off from the body by a blank line.

- **`Refs:`** — a work-tracker link. When you mention a ticket while committing,
  `anchor` appends it: a full tracker URL is used as-is; a bare id is expanded
  against `anchor.workTrackerBaseUri` (e.g. `8a1b2c3d` →
  `https://app.clickup.com/t/8a1b2c3d`). Mention nothing and there's no trailer.

## Configuration

`anchor.commitRules` adds a standing rule to every message — e.g.
`git config anchor.commitRules "prefix the subject with the affected module"`.
See the [configuring guide](/guides/configuring) for the full key set (and the
CR-side `crRules` / `mrRules` / `prRules`).
