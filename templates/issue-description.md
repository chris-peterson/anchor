# Issue description template

The shape of an issue body: which sections, in what order, and what each is for.
The `issue` skill owns the *technique* for realizing this shape — gathering the
author's intent, detecting a forge template, the output disposition. This file
owns the *shape*, so it's the place to edit as your preferences evolve.

An issue describes work **to be done**, so its raw material is the author's
intent, not a diff. Draft each section from what the author tells you in the
skill's intent-gathering step. Sections marked *(optional)* earn their place
only when they carry something a reader needs — omit them rather than pad.

**Issues lean hardest on team templates.** Issue conventions vary more between
teams than commits or CRs do, so the shape below is deliberately basic — a
fallback for when a project ships no template of its own. When a team template
exists, `anchor` composes its prose into that shape instead (see [Honoring a
project's forge template](#honoring-a-projects-forge-template) below). A standing
rule can be layered onto every issue via `anchor.issueRules`. See the
[configuring guide](/guides/configuring) for the full key set.

## 1. Context *(first heading)*

- What is being added or changed, and **why**? Lead with the why — the reader
  gets *what* from the title; the body's job is the reason.
- Who is the primary caller or consumer of this change?
- Link the driving story, ticket, or incident. Mention a tracker URL or a bare
  id and `anchor` links it — expanding a bare id against
  `anchor.workTrackerBaseUri`.

Write for a competent developer who has never seen this area of the system —
establish the business/system context in a sentence or two. That investment is
almost always worth the words.

## 2. Proposed approach

The plan and the key design decisions — **not the code**. A reader should come
away understanding *what* is being built, *how* the author intends to approach
it, and *why* the load-bearing decisions were made — not how every class is
wired together.

Reach for a diagram only when the work has shape that prose hides (a flow, a
state machine, an interaction between services). Follow `anchor`'s mermaid
conventions: hand-drawn look (`%%{ init: { 'look': 'handDrawn' } }%%`), and no
`\n` or `<br>` in node labels. Skip the diagram when the approach is linear
enough to state in a sentence.

## 3. Acceptance criteria

What "done" looks like, concrete enough that someone else could tell whether the
issue is satisfied. A checklist works for straightforward changes:

```markdown
- [ ] `POST /widgets` returns the created widget with a 201
- [ ] invalid input returns a 400 with a descriptive error
```

For behavior worth spelling out, Given/When/Then scenarios read well:

```markdown
**Scenario: expired session mid-checkout**
Given a signed-in user whose session has expired
When they submit the checkout form
Then they're redirected to re-authenticate and the cart is preserved
```

## 4. Considerations *(optional)*

Project-specific concerns the work has to account for — include only the ones
that apply, and omit the section when none do. Common ones: input validation,
caller authorization, regressions to existing behavior, external runtime
dependencies, and rollout / rollback steps for a risky change.

## Callouts: define terms and explain decisions inline

A short blockquote callout earns its place where a newcomer would otherwise be
lost — to define an unfamiliar term, or to say *why* a decision was made:

```markdown
> **Why a new endpoint instead of extending the existing one?** The two have
> different auth requirements; overloading one route would couple them.
```

Use them sparingly and keep them short. One where a reader needs it is worth a
paragraph of inline hedging; five where they don't is noise.

## Honoring a project's forge template

The sections above are `anchor`'s default shape. When a project ships its own
issue template, that template is the team's required scaffolding — `anchor`
composes its prose **into** that shape rather than replacing it.

The `issue` skill probes for one before drafting:

- **GitLab:** `.gitlab/issue_templates/*.md` (respecting the configured default
  when a project ships more than one)
- **GitHub:** `.github/ISSUE_TEMPLATE/*.md`, or the legacy
  `.github/ISSUE_TEMPLATE.md`. GitHub's `.yml` **issue forms** are a structured
  format `anchor` doesn't fill prose into — surface that one and let the author
  complete it in the web UI.

When a template is found:

- **Fill the sections it defines** with `anchor`'s prose, mapping the Context
  and Proposed approach into whatever headings the template provides.
- **Preserve its checklists and headings verbatim** — a team's wording is not
  `anchor`'s to reword or drop.
- **Strip "delete before publishing" instruction blocks** after following their
  guidance. Many templates open with author instructions meant to be removed
  before the issue is filed; do what they ask, then cut the block.
- **On a structure conflict, the team template wins.** `anchor` supplies the
  writing inside the template's sections; the prose discipline (why-first,
  terseness, define-don't-assume) still governs that writing.

This is the team-shared half of `anchor`'s customization model: per-project
knobs live in `git config anchor.*`, and issue structure lives in the forge's
own template. See the [configuring guide](/guides/configuring).
