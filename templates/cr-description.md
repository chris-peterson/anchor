# CR description template

The shape of a change-request description: which sections, in what order, and
what each is for. The `prepare-review` skill owns the *technique* for realizing
this shape — deep-link construction, before/after mermaid, screenshots, the
output checklist. This file owns the *shape*, so it's the place to edit as your
preferences evolve.

Draft each section in order, filling from the changeset and the author's
answers in Step 2. Sections marked *(rare)* or *(conditional)* earn their place
only when they carry something a reviewer needs — omit them rather than pad.

**How much to write is configurable.** `anchor.reviewBudgetMins` is the minutes
of focused review you expect this CR to get — a tight budget (≈5) leads with the
essentials and cuts asides, a generous one keeps more depth. A standing rule can
be added to every description via `anchor.crRules` (or `anchor.mrRules` /
`anchor.prRules` to override it per forge). See the [configuring
guide](/guides/configuring) for the full key set.

## 1. Context *(first heading — target a 30–60 second read)*

- What system/feature does this touch, and what does it do today?
- What problem or need drove this change? Use the author's *why* from Step 2.
- Link any ticket, incident, or design doc. Mention a tracker URL or a bare id
  and `anchor` links it — expanding a bare id against `anchor.workTrackerBaseUri`.

Context's job is to orient. If the diff plus a one-line *why* gets the reviewer
there, write that and stop. Padding Context to feel substantive is a failure
mode, not thoroughness.

## 2. Review guide

Route reviewer attention by criticality, highest-value-per-minute first. Assume
reviewers skim from the top and stop when they run out of time; put the most
important files at the top. Pick tiers that fit the changeset; skip tiers with
no meaningful material. Don't put time budgets in headers — let ordering speak.

```markdown
**Critical path**
- [`path/to/most-critical-file.ext:42`](<deep-link>) — the core change; everything else supports this

**Integration points**
- [`path/to/caller.ext:18`](<deep-link>) — how the core change is wired in
- [`path/to/config.ext:5`](<deep-link>) — new flag/setting

**Ancillary**
- [`path/to/tests.ext`](<deep-link>) — coverage for the new behavior
- [`path/to/docs.md`](<deep-link>) — updated docs

**Mechanical** — renames, formatting, generated files. Skim only.
```

**Each bullet is a pointer, not a paragraph.** A bullet is a deep link plus *at
most* a one-line trailing clause — and that clause earns its place only by
routing the reviewer: *what to look for*, or *why this hunk matters*. If the
only thing it would say is *what changed*, drop the clause and leave the bare
link. The reviewer is one click from the hunk; restating it is the "described
the *what*" failure. Never expand a bullet into numbered prose steps that walk
the edits ("remove the X block", "drop the Y key") — the deep-linked hunk
already shows them.

The Review guide routes attention; it is not where author-homework lands. A
"confirm the plan shows only the destroy of X, Y, Z" line is a check *you* run
before requesting review — it belongs in a personal checklist, not the guide
(see the `prepare-review` skill, Step 3 "What to avoid").

Use whatever tier labels fit the changeset (e.g. *Core logic / Glue / Tests /
Mechanical*, or *Security-sensitive / Refactor / Cleanup*). Headers describe the
**kind** of change, not the time it takes. "Critical" means: where a bug would
hurt most, where a reviewer's judgment adds the most value, or where the core
design decision lives. Always deep-link to the actual line — see the
`prepare-review` skill for forge-specific anchor construction. For trivial
changesets (a single file, a one-line fix), skip the tiered guide and just link
the file and say what to look for.

## 3. Approach & trade-offs *(rare — only when a reviewer would otherwise question the choice)*

Key decisions and the alternatives you rejected: "I chose X over Y because Z."
If you're defending against an objection no one raised, cut the section.

## 4. Testing *(rare — only when CI doesn't cover it and the reviewer needs to know)*

Mention testing only when it's *unusually* relevant to the reviewer's
assessment: hard-to-test code paths, environments tested against beyond CI, or
coverage decisions the reviewer might push back on. If the suite runs in CI,
reviewers already assume it ran — don't repeat.

## 5. Validation *(conditional — shared components)*

When the change is to a shared component (terraform module, library, base config
consumed by other repos by semver or git ref), the diff and rendered artifact
aren't enough on their own. Subtle issues (plan-diff churn, `set`-vs-`list`
ordering, missed `for_each` rekeys, library semver compat) only surface when the
change *composes* with a real downstream consumer.

**Ask the author what validation looks like — don't guess it.** When the
shared-component signals fire (see the `prepare-review` skill's detection
signals), the skill asks rather than inventing a checklist; the author's answer
fills this section. Record it as a single evidence row:

```markdown
- [ ] **Validated against a consumer** — `<consumer or sandbox>` — observed: `<what the author saw>`
```

Skip this section entirely for a deployable service or UI app — it ships its own
production validation.

## Honoring a project's forge template

The sections above are `anchor`'s default shape. When a project ships its own CR
template, that template is the team's required scaffolding — `anchor` composes
its prose **into** that shape rather than replacing it.

`prepare-review` probes for one before drafting:

- **GitLab:** `.gitlab/merge_request_templates/*.md` (respecting the configured
  default when a project ships more than one)
- **GitHub:** `.github/pull_request_template.md` or
  `.github/PULL_REQUEST_TEMPLATE/*.md`

When a template is found:

- **Fill the sections it defines** with `anchor`'s prose, mapping `anchor`'s
  Context and Review guide into whatever headings the template provides.
- **Preserve its checklists and headings verbatim** — a team review-prep
  checklist is the team's wording, not `anchor`'s to reword or drop.
- **On a structure conflict, the team template wins.** `anchor` doesn't reorder
  or rename the template's sections; it supplies the writing inside them. The prose
  discipline (criticality ordering, why-not-what, terseness) still governs that
  writing.

This is the team-shared half of `anchor`'s customization model: per-project knobs
live in `git config anchor.*`, and CR structure lives in the forge's own
template. See the [configuring guide](/guides/configuring).
