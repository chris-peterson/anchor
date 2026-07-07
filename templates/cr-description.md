# CR description template

The shape of a change-request description: which sections, in what order, and
what each is for. The `prepare-review` skill owns the *technique* for realizing
this shape — deep-link construction, before/after mermaid, screenshots, the
output checklist. This file owns the *shape*, so it's the place to edit as your
preferences evolve.

Draft each section in order, filling from the changeset and the author's
answers in Step 2. Sections marked *(rare)* or *(conditional)* earn their place
only when they carry something a reviewer needs — omit them rather than pad.

**Use the heading names verbatim.** The section names below — **Context**,
**Review guide**, **Approach & trade-offs**, **Testing**, **Validation** — are
the canonical headings that appear in the description as written, not
paraphrasable suggestions. Don't rename them into invented alternatives ("What
it does", "What to review", "Where it's been used") — reviewers (and your own
future passes) scan for the canonical names. The numeric prefixes (`1.`, `2.`)
in this file are template organization only; emit the bare name (`## Context`,
`## Review guide`). Omit a section that doesn't apply; never rename one.

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
design decision lives. Always deep-link to the actual line — see
`guides/cr-formatting.md` for forge-specific anchor construction. For trivial
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

## 5. Validation *(conditional — when correctness is best shown by real-world use)*

Some changes can't be fully judged from the diff and the rendered artifact alone
— their correctness only surfaces when the change *composes* with something real.
The unifying test: *would a reviewer trust this more knowing it had already
worked in the real world?* If yes, this section records that evidence. Two common
cases:

- **Shared component** consumed by other repos by semver or git ref (terraform
  module, library, base config). Subtle issues (plan-diff churn, `set`-vs-`list`
  ordering, missed `for_each` rekeys, library semver compat) only surface when
  the change *composes* with a real downstream consumer.
- **A tool, skill, or automation whose value is the work it drives.** The diff
  shows what the tool *says*; the evidence a reviewer wants is what it *did* —
  the real runs (deploys, pipelines, tickets) it has already produced.

**Ask the author what validation looks like — don't guess it.** When either
signal above fires, ask rather than inventing a checklist; the author's answer
fills this section. Record it as one or more evidence rows:

```markdown
- [ ] **Validated against a consumer** — `<consumer or sandbox>` — observed: `<what the author saw>`
- [x] **Exercised in production** — `<the real run / deploy / ticket>` — observed: `<what it produced>`
```

Skip this section when the diff plus CI already settle correctness — an ordinary
self-contained service or UI change ships its own production validation and needs
no separate evidence row.

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
- **Preserve the *reviewer-facing* structure verbatim — strip the *author-facing*
  scaffolding.** The test for every template line: is it there for the reviewer,
  or to guide *you* while authoring?
  - **Keep** — section headings, and checklists the approver acts on (a team
    review-prep checklist is the team's wording, not `anchor`'s to reword or drop).
  - **Strip** — a section's placeholder / helper text (`< Type your summary here >`,
    `(Paste any relevant logs…)`, `###### Summarize the reason…`), and the
    required / optional status annotations on its heading (`## Summary - (*Required*)`,
    `- (*Optional*)`) — those tell the author which sections to fill, not the reviewer
    anything. That text is a prompt *to the author*, not content, and must never
    survive into the shipped description. The same goes for static "reminder"
    sections whose links or prose
    are dev-time scaffolding (how-to / wiki links, "track your MR in Slack") rather
    than anything about *this* change — drop them.
- **A section you have no data for** — optional → drop it; required → prompt the
  user for content (offer an opt-out / explicit "N/A"). Never ship a bare heading
  trailed by its own filler instructions.
- **A checklist item that demands justification is answered with fact, not
  meta-commentary.** When a template says "explain why none of these apply" or
  "justify your selection," satisfy it with the factual reason Context already
  carries — not narration about which box is ticked ("which is why *None of the
  above* is checked below") or defensive softeners ("not a new capability",
  "purely additive"). State the fact that makes the box correct; don't describe the
  box.
- **On a structure conflict, the team template wins.** `anchor` doesn't reorder
  or rename the template's sections; it supplies the writing inside them. The prose
  discipline (criticality ordering, why-not-what, terseness) still governs that
  writing.

This is the team-shared half of `anchor`'s customization model: per-project knobs
live in `git config anchor.*`, and CR structure lives in the forge's own
template. See the [configuring guide](/guides/configuring).
