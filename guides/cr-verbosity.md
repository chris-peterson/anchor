# CR verbosity, calibrated

`anchor.crVerbosity` is an integer from 1 to 100 setting where a CR description
sits between brevity and thoroughness. `100` is the shape the
[CR-description template](/templates/cr-description) describes in full; the
default of `50` leans well toward the brief end of it.

**It isn't a word budget.** No count is being hit, nothing is truncated at a
limit, and two changesets at the same setting will run to different lengths — a
five-file refactor has more that a reviewer must be pointed at than a one-line
fix does. The number says how hard to lean on brevity when the two pull against
each other, and the balance point is the answer, not an arithmetic target.

Which is why an adjective — "lean", "balanced" — doesn't settle what a number
buys you. This page does: one real changeset, drafted at five settings, so you
pick by reading output.

> In the renderings below, each Review-guide entry that reads `` `path:42` `` is
> a **deep link** in the real thing — one click from the reviewer to that line.
> They're shown unlinked here because the targets are a constant at every
> setting: deep links are the one thing verbosity never cuts, so what changes
> between renderings is the words around them.

## Verbosity abbreviates; it never removes a section

**Which sections a description has is the [template](/templates/cr-description)'s
call, not this dial's.** The template already states the condition each section
has to meet — Approach & trade-offs only for a contested choice, Testing only
where CI doesn't cover it, Validation only where real-world evidence settles
something the diff can't. A section that meets its condition is in the
description at every setting, down to `1`. A section that doesn't was never in
it, at any setting.

This is the whole point of the key. Removing a section removes *information*, and
that is the thing `reviewBudgetMins` already does and the reason it was the wrong
lever for length: turning the budget down buys fewer words by giving up coverage.
A verbosity dial that also dropped sections would be a second way to lose content
and no way to gain brevity that isn't loss.

So what the dial moves is prose, in this order:

1. **Asides and supporting depth** — the clause that qualifies a claim the
   reviewer wasn't going to dispute.
2. **Explanation, down to the load-bearing claim** — each section keeps what it
   is *for* and sheds the reasoning around it. Approach & trade-offs goes from
   "here's the decision, the alternative, and why the alternative loses" to the
   decision and one clause of why.
3. **Review-guide clauses, then tiers** — the trailing clause on each bullet
   shortens to the part that routes attention, then the tier headings collapse
   into a single list.
4. **Context folds** — the second paragraph into the first, then the first to its
   *why* sentence.

Each section has a floor it reaches and stops at, and every one of them is still
a section: Context is one sentence of *why*; the Review guide is its bare deep
links; a conditional section is its single load-bearing sentence, or for
Validation, the evidence row alone. The deep links in particular are the
highest-value-per-minute part of any description — the reviewer is one click from
the change — so a low setting drops the words around them, never the links.

That floor is why the bottom of the range flattens out. Every section the
template kept still has to be present, and each has a length of its own, so the
shortest setting lands well above where a proportional reading of the number
would put it.

There are no thresholds either — no setting at which a particular thing switches
off. The list is the mechanism: work down it until the draft balances where the
setting asks, and stop. A high setting never gets past the asides; one near the
floor works through the whole list.

Verbosity steers length, never register. A low setting buys fewer words, not
louder ones — the no-hyperbole discipline in the `prepare-review` skill's "What
to avoid" governs at every setting, and `1` is no more license for a punchy
tagline than `100` is.

## How it composes with `anchor.reviewBudgetMins`

The two knobs answer different questions, and neither overrides the other:

- **`reviewBudgetMins`** decides **what to include** — how many of the
  changeset's topics survive into the description at all.
- **`crVerbosity`** decides **how much prose** the surviving topics get.

Budget picks the content set first; verbosity then sets how much prose carries
it. So a tight budget at `crVerbosity 100` is a few topics explained in full, and
a generous budget at `crVerbosity 1` is broad coverage in telegraphic form. The
floor above — a why sentence and the deep links — is what neither knob cuts.

## The same changeset at five settings

This page's own changeset, drafted five times. Each draft came from a separate
agent given the diff, the template, and one setting, with no sight of what the
others produced. The prose is unedited.

The sections barely move — which is the point. What changes is how much is said
inside them:

| Setting | Sections |
|---|---|
| `100` | Context · Review guide · Approach & trade-offs · Testing |
| `75` | Context · Review guide · Approach & trade-offs · Testing |
| `50` | Context · Review guide · Approach & trade-offs · Testing |
| `25` | Context · Review guide · Approach & trade-offs · Testing |
| `1` | Context · Review guide · Approach & trade-offs |

`1` is the one that differs, and not because of the dial: that drafter judged
Testing's condition unmet, where the other four judged it met. Section presence
rests on a condition each drafter evaluates fresh, so it can wobble between
independent passes — the dial itself never moves it.

### `100`

<details>
<summary>the reasoning behind every decision, spelled out</summary>

#### Context

`prepare-review` drafts CR descriptions, and how much it writes is steered by `git config anchor.*` keys. Until now the only key that touched length was `anchor.reviewBudgetMins` — the minutes of focused review you expect a CR to get. But the budget decides *what a description covers*: turn it down to get fewer words and you also lose topics. Descriptions were running too long, and a team that wanted the same coverage written shorter had nothing to set. This adds `anchor.crVerbosity`, an integer from 1 to 100 for where a description sits between brevity and thoroughness, as a second axis that resolves independently of the budget. Closes #47.

It ships at `50`, so descriptions come out markedly briefer than 1.2.0 for everyone who configures nothing, and `git config anchor.crVerbosity 100` restores the old shape. `anchor.mrVerbosity` / `anchor.prVerbosity` override it per forge exactly as the `*Rules` keys already do. There's no script plumbing in the changeset — `prepare-review.sh` already collects every `anchor.*` key into `ANCHOR_CONFIG` — so the whole change is prose across the template, the skill, and the guides, plus a new calibration page for picking a number.

#### Review guide

**Critical path — the invariant, stated four times**

- `templates/cr-description.md:31` — the gate: the `(rare)` / `(conditional)` markers decide which sections a description *has*, and they're the only thing that does. Verbosity abbreviates a section, never removes one. Everything else in the changeset restates this, so if the wording is wrong here it's wrong in four places.
- `skills/prepare-review/SKILL.md:230` — the behavior itself: the order the dial works down (asides → explanation → Review-guide clauses, then tiers → Context's second paragraph) and the floor each section stops at. No thresholds anywhere, by design — this ordering is the whole mechanism.
- `skills/prepare-review/SKILL.md:226` — the key as the drafting model sees it: the `50` default, forge-key resolution mirroring `crRules` but independent of it, and the clamp for an out-of-range or non-integer value.
- `guides/cr-verbosity.md:24` — the same invariant argued for a human reader, including *why* a dial that dropped sections would just be a second `reviewBudgetMins`.

**The per-section floors** — one `At lower verbosity` note per section, and they're what the skill defers to for "how short is too short"

- `templates/cr-description.md:71` — Context folds to the *why* sentence. Paired with `skills/prepare-review/SKILL.md:12`, which reframes the existing two-paragraph Context cap as the shape at `100` rather than the shape always.
- `templates/cr-description.md:121` — the Review guide keeps its deep links at every setting and sheds the words around them. This one is the protected floor; check it says so unambiguously.
- `templates/cr-description.md:133`, `templates/cr-description.md:145`, `templates/cr-description.md:179` — Approach & trade-offs, Testing, Validation. Each keeps its load-bearing claim (for Validation, the evidence rows) and drops the reasoning around it.

**Config surface**

- `guides/configuring.md:58` — "Two length knobs", the section that has to leave a reader able to pick between them: budget for "covers things I don't care about", verbosity for "covers the right things at too much length".
- `guides/configuring.md:155` — the `cr` / `mr` / `pr` prefix convention now governs both pairs and resolves them independently, so a `prVerbosity` with no `prRules` changes length on GitHub and leaves the rules alone.
- `guides/configuring.md:31` — the `mrVerbosity` / `prVerbosity` row.
- `skills/prepare-review/SKILL.md:268` — Tone, generalized from "a tight review budget is not license for marketing punch" to cover both knobs. The point that matters: at a low setting the few words left are all a reviewer gets, so brevity buys fewer words, not louder ones.

**Ancillary**

- `SPEC.md:504` — CONF-07..10: the key and its default, abbreviate-not-remove, section presence coming from the template plus budget alone, and length-not-register.
- `STATUS.md:32` — coverage row, CONF-01..06 → CONF-01..10.
- `CHANGELOG.md:3` — the Unreleased entry, which is where the default-changes-for-everyone note has to be legible.
- `docs/README.md:131`, `docs/_sidebar.md:20` — the new guide in both indexes.

#### Approach & trade-offs

**A second key rather than reworking `reviewBudgetMins`.** The budget already answers a question worth answering — how many of the changeset's topics survive into the description at all — and overloading it with length is exactly what made a short description cost coverage. Two keys that resolve independently means a tight budget at `crVerbosity 100` is a few topics explained in full, and a generous budget at `crVerbosity 1` is broad coverage in telegraphic form. Both are reachable now; neither was before.

**Default `50`, not `100`.** This changes output for everyone who sets nothing, which is the kind of thing worth flagging rather than burying. The alternative — default to `100` and make brevity opt-in — would have left the default sitting where the complaint was, so the people who reported the problem would have to know a key exists to stop having it. `100` restores the previous shape for anyone who wants it, and the changelog says so.

**No word counts, and no per-level thresholds.** Nothing is counted and nothing is truncated: two changesets at the same setting run to different lengths, because a five-file refactor has more a reviewer must be pointed at than a one-line fix does. Stating a target word count would read as a quota to hit. Per-level cutoffs ("at 40, drop Testing") were the other option and would have encoded the same ordering a second time across six files to keep in sync, while answering nothing the ordering doesn't already answer. What's written down instead is the order the dial works down and the floor each section stops at.

**Verbosity abbreviates; it never removes.** Falls out of the first trade-off — removing a section removes information, and that's `reviewBudgetMins`'s job. Two things survive at every setting, including `1`: one sentence of *why*, and the Review guide's deep links, which are the highest value per minute a reviewer has.

#### Testing

Nothing in CI exercises this. `tests/` is shell tests over `scripts/`, and no script changed — the dial is prompt text end to end, read by the model at draft time. So the review *is* the test: the check is that the four sites stating the invariant agree with each other.

</details>

### `75`

<details>
<summary>the decisions keep their alternatives; the asides go</summary>

#### Context

`anchor`'s CR descriptions were running too long, and the only knob that touched length was `anchor.reviewBudgetMins` — which decides *what a description covers*. Turning it down to get fewer words also drops content, so a team that wanted the same coverage written shorter had nothing to set. This adds `anchor.crVerbosity` as a second, orthogonal axis: an integer 1–100 for where a description sits between brevity and thoroughness, with `anchor.mrVerbosity` / `anchor.prVerbosity` overriding it per forge the way the `*Rules` keys already do. Closes #47.

It ships at `50`, so descriptions come out shorter for everyone who sets nothing, and `100` is the template's full shape. The load-bearing constraint is that the dial only abbreviates: which sections a description has stays the CR template's call, decided by each section's `(rare)` / `(conditional)` condition, and a section that meets its condition is present at every setting down to `1`. Dropping sections is what the budget knob already does, which is what made it the wrong lever for length.

#### Review guide

**Critical path**

- `skills/prepare-review/SKILL.md:226` — the new config bullet: how the forge key resolves, the `50` default, the clamp on an out-of-range value
- `skills/prepare-review/SKILL.md:230` — the order the dial works down and where each section bottoms out; there are no per-level thresholds anywhere
- `templates/cr-description.md:31` — the sections gate — the template decides presence, verbosity only decides length

**Per-section floors** — the template change that makes the gate above enforceable

- `templates/cr-description.md:71` — Context folds to its *why* sentence and stops
- `templates/cr-description.md:121` — deep links survive every setting; only the words around them shrink
- `templates/cr-description.md:133` — Approach & trade-offs, down to the decision and one clause
- `templates/cr-description.md:145` — Testing, down to the gap itself
- `templates/cr-description.md:179` — Validation, down to the evidence rows and no further

**The new guide, and the user-facing wording**

- `guides/cr-verbosity.md:24` — the argument the whole key rests on: abbreviate, never remove
- `guides/cr-verbosity.md:40` — the same abbreviation order stated for the reader rather than the drafter; worth reading against `SKILL.md:230` to check the two agree
- `guides/configuring.md:30` — the key's table row, where most people will meet it — check the summary of what a low setting does against the template's rule
- `guides/configuring.md:58` — "Two length knobs", the section that tells someone which one to reach for
- `guides/configuring.md:149` — the `cr` / `mr` / `pr` convention now covers both pairs and resolves them independently
- `skills/prepare-review/SKILL.md:12` — Context's two-paragraph ceiling reframed as the shape at `100`
- `skills/prepare-review/SKILL.md:268` — the register guard: a low setting buys fewer words, not louder ones

**Ledger and nav** — skim only

- `SPEC.md:504` — CONF-07..10
- `STATUS.md:32`
- `CHANGELOG.md:7`
- `docs/README.md:131`
- `docs/_sidebar.md:20`

#### Approach & trade-offs

**Default `50`, not `100`.** Shipping at `100` would have left every description exactly as long as it is today and made brevity opt-in, which puts the default right back where the complaint was. `50` moves everyone who configures nothing; `git config anchor.crVerbosity 100` restores the previous shape for anyone who wants it.

**One ordered list, no per-level thresholds.** The alternative was a table of what drops at each level. What's written down instead is the order the dial works down — asides, then explanation, then Review-guide clauses and tiers, then Context's second paragraph — and where a draft lands falls out of working down it. Encoding that ordering a second time as cutoffs would be six sites to keep in sync and answers nothing the order already does. Same reason no target word count appears anywhere: a stated number reads as a quota, and nothing here counts or truncates.

#### Testing

No script changed — `prepare-review.sh` already collects every `anchor.*` key into `ANCHOR_CONFIG`, so the key needed no plumbing and the `tests/` suite has nothing new to run. Nothing in CI asserts that a setting produces a given length, and nothing can: this behavior is prompt text a model reads at draft time, so reading the wording is the verification available here.

</details>

### `50` — the default

<details>
<summary>each section down to its load-bearing claim</summary>

#### Context

`anchor`'s CR descriptions were running too long. The only knob that touched length was `anchor.reviewBudgetMins`, which decides *what a description covers* — turning it down to get fewer words also drops content, so a team that wanted the same coverage written shorter had nothing to set. This adds `anchor.crVerbosity` as a second, orthogonal axis: an integer 1–100 for how much prose the covered material gets, with `mrVerbosity` / `prVerbosity` overriding it per forge the way the `*Rules` keys already do. It ships at `50`, so descriptions come out briefer for everyone who sets nothing. Closes #47.

#### Review guide

**Critical path**
- `templates/cr-description.md:31` — which sections a description has stays the template's call, not the dial's; everything else depends on this holding
- `skills/prepare-review/SKILL.md:226` — how the drafting step resolves the key and applies it after the section list is settled; `ANCHOR_CONFIG` already carries every `anchor.*` key, so no script change
- `templates/cr-description.md:71` — first of the per-section "At lower verbosity" notes; each section now names what it sheds and the floor it stops at

**Integration points**
- `guides/configuring.md:30` — the key's row in the config table, with the `mr`/`pr` overrides under it
- `guides/configuring.md:58` — "Two length knobs": which of the two to reach for
- `guides/cr-verbosity.md:24` — new guide; the abbreviate-never-remove argument and the order the dial works down

**Ancillary**
- `SPEC.md:504` — CONF-07..10
- `CHANGELOG.md:3` — unreleased entry
- `STATUS.md:32` — coverage row

**Mechanical**
- `docs/README.md:131`, `docs/_sidebar.md:20` — guide index entries

#### Approach & trade-offs

Shipping at `50` rather than `100` means the default output changes for everyone who sets nothing; `git config anchor.crVerbosity 100` restores the previous shape. Defaulting to `100` and making brevity opt-in would have left the default where the complaint was.

What's written down is the order the dial works down — asides, then explanation, then Review-guide clauses and tiers, then Context's second paragraph — and not per-level cutoffs, which would encode the same ordering a second time in every place a section states its floor.

#### Testing

The behavior is prompt text, so the shell suite under `tests/` doesn't reach it — nothing executes a drafting run, and the check on the semantics is reading the template and the skill.

</details>

### `25`

<details>
<summary>a sentence or two per section; Review guide flattens</summary>

#### Context

`anchor`'s CR descriptions were running too long, and the only knob that touched length was `anchor.reviewBudgetMins` — which decides *what* a description covers, so turning it down to get fewer words also drops content. A team that wanted the same coverage written shorter had nothing to set. `anchor.crVerbosity` is that second, orthogonal axis: an integer 1–100 for where a description sits between brevity and thoroughness, shipping at `50`, with `mrVerbosity` / `prVerbosity` overriding it per forge the way the `*Rules` keys already do. Closes #47.

#### Review guide

- `skills/prepare-review/SKILL.md:226` — where the dial is resolved and applied; the core change
- `templates/cr-description.md:31` — the template's conditions, not the dial, decide which sections appear
- `templates/cr-description.md:71` — per-section "At lower verbosity" floors (also `:121`, `:133`, `:145`, `:179`)
- `guides/cr-verbosity.md:24` — the abbreviation order the dial works down, and where each section stops
- `guides/configuring.md:30` — new key rows; "Two length knobs" at `:58` separates the two axes
- `SPEC.md:504` — CONF-07..10
- `CHANGELOG.md:7`, `docs/_sidebar.md:20`, `STATUS.md:29` — skim

#### Approach & trade-offs

Ships at `50`, not `100` — everyone gets briefer descriptions without setting anything, and `crVerbosity 100` restores the old shape; making brevity opt-in would have left the default where the complaint was. No per-level thresholds: the documented order (asides → explanation → Review-guide clauses and tiers → Context's second paragraph) is the whole mechanism, and cutoffs would be the same ordering encoded a second time.

#### Testing

This behavior lives entirely in prompt text, so no CI suite executes it — whether a given setting produces the length it claims can only be checked by reading drafted output.

</details>

### `1` — the floor

<details>
<summary>every section at its floor and nothing more</summary>

#### Context

The only knob that touched CR-description length was `anchor.reviewBudgetMins`, which decides *what a description covers* — turning it down to get fewer words also drops content, so `anchor.crVerbosity` adds a second, orthogonal axis that shortens the prose instead. Closes #47.

#### Review guide

- `skills/prepare-review/SKILL.md:226` — how the dial is resolved and applied while drafting
- `templates/cr-description.md:31` — which sections a description has stays the template's call, not the dial's
- `guides/cr-verbosity.md:24`
- `guides/configuring.md:30`
- `SPEC.md:504`
- `CHANGELOG.md:7`
- `STATUS.md:32`
- `docs/README.md:131`
- `docs/_sidebar.md:20`

#### Approach & trade-offs

Ships at a default of `50` rather than `100`, so descriptions come out shorter without anyone configuring anything; `anchor.crVerbosity 100` restores 1.2.0's shape.

</details>

## Picking a number

Read the two renderings either side of where you're inclined to land and pick
the one whose Review guide you'd rather receive — that section is what a reviewer
spends their first thirty seconds in, and it's where the settings differ most.
Then set it where it belongs: `--global` if it's your own reading preference,
project-local if it's this repo's convention.

```bash
git config --global anchor.crVerbosity 25   # you like them short, everywhere
git config anchor.crVerbosity 90            # this repo's reviewers want the depth
git config anchor.prVerbosity 25            # ...but keep GitHub PRs lean
```

See the [configuring guide](/guides/configuring) for the `mr` / `pr` override
rules and the rest of the key set.
