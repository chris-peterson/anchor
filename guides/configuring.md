# Configuring `anchor`

`anchor` ships with opinions about *how a message reads* — its tone, level of
detail, review emphasis, and how it budgets a reviewer's time. That voice travels
with every commit and CR it writes; the default shapes are documented in the
[commit-message](/templates/commit-message) and
[CR-description](/templates/cr-description) templates. When a team-specific
template exists, `anchor` delivers its prose **into that format** — your
structure, `anchor`'s voice, both intact. You extend it around that voice through
two surfaces, neither of which commits an `anchor`-specific file to your repo:

- **Per-project / personal knobs** — `git config anchor.<key>`. Project-local
  lives in `.git/config` (never tracked); add `--global` for all your repos.
- **Team CR scaffolding** — your forge's native template
  (`.gitlab/merge_request_templates/*.md`, `.github/pull_request_template.md`).
  `prepare-review` detects and composes into it — put the team review-prep
  checklist there.

## Defaults

What `anchor` does when you've set nothing. Every value here is what the skills
draft against out of the box, so this table is the one place to look before
deciding a key is worth setting.

The four verbosity dials are listed in lifecycle order, and they descend:
`issueVerbosity` `75` → `commitVerbosity` `50` → `crVerbosity` `25` →
`releaseVerbosity` `10`. See [Length knobs](#length-knobs) for why.

| Key | Default | What that gets you |
|---|---|---|
| [`anchor.reviewBackend`](#key-reviewbackend) | per skill | Each skill picks the shape its artifact wants — `editor` for a drafted document, `revdiff` for a changeset. Setting it names one tool for all of them. |
| [`anchor.<skill>.reviewBackend`](#key-skill-reviewbackend) | the umbrella key, else per skill | A skill reviews in the backend above until you give that skill its own. |
| [`anchor.reviewBudgetMins`](#key-reviewbudgetmins) | `10` | Descriptions are written for ten minutes of focused review — enough for the change and the topics around it. |
| [`anchor.issueVerbosity`](#key-issueverbosity) | `75` | Issue bodies run long: the people who pick the work up need the context in the issue. |
| [`anchor.commitVerbosity`](#key-commitverbosity) | `50` | Commit bodies run to the why plus the context the diff doesn't show. |
| [`anchor.crVerbosity`](#key-crverbosity) | `25` | CR descriptions stay near the brief end — a reviewer on a deadline wants pointing, not explaining. |
| [`anchor.releaseVerbosity`](#key-releaseverbosity) | `10` | Release notes run to each change as its effect on someone using the project, and stop. |
| [`anchor.mrVerbosity`](#key-mr-pr-verbosity) / [`anchor.prVerbosity`](#key-mr-pr-verbosity) | `anchor.crVerbosity` | No forge split — GitLab and GitHub get the same length until you set one. |
| [`anchor.watchPipelineAfterPush`](#key-watchpipelineafterpush) | `true` | Every push-side skill watches the pipeline that push started and reports it. |
| [`anchor.<skill>.watchPipelineAfterPush`](#key-skill-watchpipelineafterpush) | the umbrella key | A skill follows the setting above until you give that skill its own. |
| [`anchor.workTrackerBaseUri`](#key-worktrackerbaseuri) | none | Mentioning a bare ticket id gets you no link — mention a full URL, or set this. |
| [`anchor.commitRules`](#key-commitrules) | none | The default commit-message rules apply, with nothing layered on. |
| [`anchor.issueRules`](#key-issuerules) | none | The default issue rules apply, with nothing layered on. |
| [`anchor.crRules`](#key-crrules) | none | The default CR-description rules apply, with nothing layered on. |
| [`anchor.mrRules`](#key-mr-pr-rules) / [`anchor.prRules`](#key-mr-pr-rules) | none | No forge split — GitLab and GitHub get the same rules until you set one. |
| [`anchor.crTemplateRepo`](#key-crtemplaterepo) | none | Template resolution stops at what the repo and the forge supply. |

Absent keys keep these; the skills never invent a value for a key you haven't
set.

## Keys

Keys use git's standard camelCase convention (like `init.defaultBranch` or
`commit.gpgSign`). git stores and matches them case-insensitively, so the case is
purely for readability. Defaults are in [the table above](#defaults) rather than
repeated in each entry.

### `anchor.workTrackerBaseUri` :id=key-worktrackerbaseuri

```bash
git config anchor.workTrackerBaseUri https://app.clickup.com/t/
```

The base URL of your work tracker. When you mention a ticket, `commit` adds a
`Refs:` trailer and `prepare-review` links it in the CR. See
[Work-tracker references](#work-tracker-references).

### `anchor.reviewBackend` :id=key-reviewbackend

```bash
git config anchor.reviewBackend revdiff
```

Which review tool the skills launch, overriding the per-skill defaults in
[A backend per artifact](#a-backend-per-artifact): `revdiff` or `editor`.

Both return a normalized review verdict, which is the whole point of the key —
git's own difftool is deliberately not on the list, because a changeset shown
without a verdict ends in "you saw it, approve?", and that is a rubber stamp
rather than a review.

`revdiff` is a terminal-native reviewer that also handles hg/jj repos; it needs
the revdiff plugin installed. `editor` is the other shape of the step: instead of
commenting on the draft, you edit it.

How the chosen tool renders the diff is its own knob, not an `anchor.*` key: see
[Review-backend config](#review-backend-config) (per backend:
[`revdiff`](#review-backend-config-revdiff), [`editor`](#review-backend-config-editor)).

### `anchor.<skill>.reviewBackend` :id=key-skill-reviewbackend

```bash
git config anchor.commit.reviewBackend editor
```

The same choice for one skill, overriding the umbrella key above. See
[A backend per artifact](#a-backend-per-artifact).

### `anchor.reviewBudgetMins` :id=key-reviewbudgetmins

```bash
git config anchor.reviewBudgetMins 10
```

How many minutes of focused attention you expect this CR to get. It's an
*input*, not a length cap: a tight budget (≈5) makes `prepare-review` lead with
the essentials and cut asides hard; a generous one (≈30) keeps more supporting
context and depth.

It steers *what to include*, not the tone — a tight budget is no license for
punchy or marketing framing. For *how long* the result runs, see
[`anchor.crVerbosity`](#key-crverbosity) and [Length knobs](#length-knobs).

### `anchor.issueVerbosity` :id=key-issueverbosity

```bash
git config anchor.issueVerbosity 100
```

Where an issue body sits between brevity and thoroughness. It sits highest of
the four because the audience is the people who'll do the work, and what reads
as detail to anyone else saves them a conversation.

Below `100` the prose tightens in order — callouts, then the approach's
explanation down to its load-bearing decisions, then Context's second paragraph.
**Acceptance criteria are never abbreviated**: they say what done means, so
they're the issue's floor the way the deep links are the CR's.

### `anchor.commitVerbosity` :id=key-commitverbosity

```bash
git config anchor.commitVerbosity 25
```

The same dial applied to the commit message body. Below `100` the body tightens
in order — asides, then the decisions-and-alternatives prose, then the context
paragraph — down to a floor of one sentence of *why*.

The subject line's format rules and the `Refs:` trailer stand at every setting,
and a trivial change still earns a subject-only message.

### `anchor.crVerbosity` :id=key-crverbosity

```bash
git config anchor.crVerbosity 50
```

Where a CR description sits between brevity and thoroughness, as an integer from
1 to 100. It is not a word budget — nothing is counted or truncated; the number
says how hard to lean on brevity when the two pull against each other.

`100` is the [CR-description template](/templates/cr-description)'s full shape;
below that the prose tightens, in the order the
[verbosity guide](/guides/cr-verbosity) sets out.

**It abbreviates sections, never removes them** — which sections a description
has is the template's call, so one that meets its condition is present at every
setting, down to its floor. It never cuts the *why* sentence or the Review
guide's deep links, and it steers length only, never register. See the
[`mr` / `pr` overrides](#key-mr-pr-verbosity) below.

### `anchor.mrVerbosity` / `anchor.prVerbosity` :id=key-mr-pr-verbosity

```bash
git config anchor.prVerbosity 25
```

Forge-specific overrides of [`anchor.crVerbosity`](#key-crverbosity):
`mrVerbosity` applies on GitLab, `prVerbosity` on GitHub. When set, the
forge-specific key replaces `crVerbosity` for that forge; otherwise `crVerbosity`
applies.

### `anchor.releaseVerbosity` :id=key-releaseverbosity

```bash
git config anchor.releaseVerbosity 40
```

The same dial applied to release notes. It sits lowest of the four: the audience
is everyone using the project, and most of them are reading to find out whether
this release affects them.

Below `100` the notes shed rationale first, then the consequences a reader can
infer, down to a floor of each change stated as its effect on someone using the
project. **Every entry survives at every setting**, as do a breaking change's
migration steps — the dial shortens entries, it doesn't drop them.

### `anchor.commitRules` :id=key-commitrules

```bash
git config anchor.commitRules "prefix the subject with the affected module"
```

An extra rule layered onto `anchor`'s default commit-message rules, applied to
every message it drafts.

### `anchor.issueRules` :id=key-issuerules

```bash
git config anchor.issueRules "always include an acceptance-criteria checklist"
```

An extra rule layered onto `anchor`'s default issue rules, applied to every issue
the `issue` skill drafts.

### `anchor.crRules` :id=key-crrules

```bash
git config anchor.crRules "@-mention the on-call lead"
```

An extra rule layered onto the default CR-description rules — the forge-agnostic
default. See the [`mr` / `pr` overrides](#key-mr-pr-rules) below.

### `anchor.mrRules` / `anchor.prRules` :id=key-mr-pr-rules

```bash
git config anchor.prRules "fill in the Risk & rollback section"
```

Forge-specific overrides of [`anchor.crRules`](#key-crrules): `mrRules` applies
on GitLab, `prRules` on GitHub. When set, the forge-specific key replaces
`crRules` for that forge; otherwise `crRules` applies.

### `anchor.crTemplateRepo` :id=key-crtemplaterepo

```bash
git config anchor.crTemplateRepo my-group/ci-templates
```

A repo holding the CR template to use when neither this repo nor the forge's own
inheritance supplies one. `prepare-review` reads it last, so it never overrides a
template the team already ships.

Give it as `group/project` on GitLab or `owner/repo` on GitHub; the template is
looked for in that repo's usual locations.

### `anchor.watchPipelineAfterPush` :id=key-watchpipelineafterpush

```bash
git config anchor.watchPipelineAfterPush false
```

Whether a skill that pushes then watches the pipeline that push triggered and
reports it. Applies to every push-side skill (`commit`, `resolve-feedback`,
`prepare-review`). See
[Watching the pipeline after a push](#watching-the-pipeline-after-a-push).

### `anchor.<skill>.watchPipelineAfterPush` :id=key-skill-watchpipelineafterpush

```bash
git config anchor.prepare-review.watchPipelineAfterPush false
```

The same knob for one skill, overriding the umbrella key above.

## In depth

### Work-tracker references

`anchor` carries a work-tracker reference into a commit or CR when you **mention
one** — it doesn't scrape it from the branch or guess. Mention a ticket while
committing (or have it in the changeset's context) and it lands as a `Refs:`
commit trailer and a link in the CR description. Two forms work:

- **A full tracker URL** is used as-is — e.g. `https://app.clickup.com/t/8a1b2c3d`
  or the workspace-scoped `https://app.clickup.com/t/9012345/8a1b2c3d`.
- **A bare id** is appended to `anchor.workTrackerBaseUri` — mention `8a1b2c3d`
  with the base set to `https://app.clickup.com/t/` and `anchor` builds the URL.
  Ids may be multi-segment (`9012345/8a1b2c3d`).

If you don't mention a ticket, `anchor` leaves the trailer off — it won't prompt
for one on every commit.

### Length knobs

Each artifact has its own verbosity dial, and the four defaults descend along the
lifecycle:

| | Dial | Default | Written for |
|---|---|---:|---|
| Issue | `anchor.issueVerbosity` | `75` | the few people who'll do the work |
| Commit | `anchor.commitVerbosity` | `50` | whoever lands here later, bisecting or reading `git log` |
| CR | `anchor.crVerbosity` | `25` | reviewers, working through a queue |
| Release | `anchor.releaseVerbosity` | `10` | everyone using the project |

Each step out from the work widens the audience and narrows what they came for,
so brevity is warranted further out. The paragraph of background that saves the
implementer a conversation is the paragraph a release-notes reader skims past to
find whether this affects them. Set one to reshape one artifact; the four resolve
independently.

On CRs a second knob crosses that one. `reviewBudgetMins` and `crVerbosity` both
make a description shorter, and they do it on different axes — which is why
turning one down is not a substitute for the other:

- **`reviewBudgetMins` decides what to include.** How many of the changeset's
  topics survive into the description at all. Turn it down and you get fewer
  things covered.
- **`crVerbosity` decides how much prose those topics get.** Turn it down and you
  get the same coverage, written shorter.

Budget picks the content set; verbosity sets how much prose carries it.
A tight budget at `crVerbosity 100` is a few topics explained in full; a generous
budget at `crVerbosity 1` is broad coverage in telegraphic form. Reach for the
budget when descriptions cover things you don't care about, and for verbosity
when they cover the right things at too much length.

Neither knob cuts below the floor — one sentence of *why*, and the Review guide's
deep links. [The verbosity guide](/guides/cr-verbosity) renders one real changeset
at five settings, which is the way to pick a number.

### Watching the pipeline after a push

A push is what starts CI, so the skill that pushed is the one holding the answer
to whether the commit went green. `commit`, `resolve-feedback`, and
`prepare-review` each watch that pipeline to a terminal state and report it as a
table of runs and jobs.

Two things bound it, both handled for you:

- **One report per pipeline.** The skills gate on the runs already reported, so
  a CR opened on the commit `commit` just pushed and reported doesn't report the
  same pipeline a second time. A rebase, a follow-up commit, a re-run, or a
  pipeline that only opening the CR starts (`on: pull_request`) are each a
  pipeline nobody has seen, and get their own report.
- **A bounded wait.** The watch stops at the poll ceiling
  (`PIPELINE_WATCH_TIMEOUT`, 30 minutes by default) and reports the last state
  with a link rather than waiting on a pipeline that never settles. A repo whose
  CI doesn't run on push reports that no pipeline appeared.

Turn it off per skill or across the board — most useful where one skill's report
is the noisy one:

```bash
git config anchor.prepare-review.watchPipelineAfterPush false  # this skill only
git config anchor.watchPipelineAfterPush false                 # every push-side skill
```

A per-skill key wins over the umbrella one in both directions, so an umbrella
`false` plus `anchor.commit.watchPipelineAfterPush true` reports the commit you
just made and nothing else.

### Review-backend config

`anchor` hands the review backend only what the review *is*: the diff range (or
the two paths), the header, and the channel it reads the verdict back from. How
the diff *looks* stays the tool's own knob, so set your preferences in the tool's
config rather than looking for an `anchor.*` key. `anchor` passes no presentation
flags, so nothing it sends overrides what you set there.

#### Review-backend config: `revdiff`

revdiff reads
[`~/.config/revdiff/config`](https://revdiff.com/docs.html#config-file), an INI
file whose keys are the long flag names:

```ini
compact          = true
cross-file-hunks = true
theme            = dracula
wrap             = true
```

It reads that file itself, so the same preferences apply whether you run it by
hand or `anchor` opens it.

Prefer the file over the matching `REVDIFF_*` environment variables. `anchor`
opens the TUI in a split of your terminal session, and a split starts with a
named set of the caller's environment — `PATH`, the locale, and
`EDITOR`/`VISUAL` — rather than a copy of your shell's. So an
`export REVDIFF_WRAP=true` in `.zshrc` reaches a `revdiff` you start yourself and
can miss the one `anchor` opens. `REVDIFF_CONFIG` is the exception: `anchor`
reads it and passes the path through as `--config`. See
[revdiff's options](https://revdiff.com/docs.html#options) for the full list.

revdiff renders in a terminal, so this backend needs a session `anchor` can
split — iTerm2 today. Where there is none, a revdiff review reports `no-verdict`
naming that rather than opening on nothing.

#### Review-backend config: `editor`

The `editor` backend opens the editor git would open, so the knob is git's own:

```bash
git config core.editor "code --wait"   # or set VISUAL / EDITOR
```

`anchor` walks these in order and takes the first that names something:

| # | Source | Notes |
|--:|---|---|
| 1 | `GIT_EDITOR` | Ignored when it is a no-op (`true`, `:`) — the way an agent harness keeps git from opening editors. Honoring it would open nothing, change nothing, and read as approval. |
| 2 | `git config core.editor` | The one to set if you want this decided per repo or globally. |
| 3 | `VISUAL`, then `EDITOR` | Where git looks next. Claude Code exposes no editor setting of its own, and its transcript viewer documents these two, so one value can steer both it and `anchor`. |
| 4 | git's compiled default | Whatever a plain `git commit` opens here, usually `vi` — when there is a terminal to host it. |
| 5 | A blocking VS Code on `PATH` | `code --wait`, then `code-insiders --wait`. `anchor`'s own preference, not git's, and where it lands with nowhere to put a terminal. |

Rungs 4 and 5 are where `anchor` goes past git: git's chain ends at 4, and a
session that exports `GIT_EDITOR=true` with nothing else set would otherwise
have no editor at all on a machine where `git commit` opens one.

Which of the two comes first depends on where `anchor` can draw. Inside tmux or
an iTerm2 session it can open a terminal (see below), so it takes the editor
`git commit` would open and puts it in a pane it labels, focuses, and closes
behind you. With nowhere to host a terminal — a plain SSH session, a CI step —
VS Code's own window is the only thing that reaches you at all.

Both rungs are `anchor` guessing. When it lands on one, it says so as it opens
the review and names the key that would settle it — so the hint arrives next to
the editor you didn't pick, and stops once you have.

To change it, set rung 2 or 3 — both override everything under them:

```bash
git config --global core.editor "vim"           # every repo
git config core.editor "code --wait"            # this repo only
export VISUAL="code --wait"                     # this shell, and Ctrl+G with it
```

A GUI editor has to **block** — `--wait` on VS Code, `-w` on Sublime and
TextMate. Without it the editor returns the instant it opens and `anchor` reads
an untouched draft as one you approved. That's also why rung 5 stays narrow to
the VS Code family: `--wait` is the flag it knows blocks, so any other editor is
a `core.editor` away rather than a guess.

A *terminal* editor needs a terminal, and the session `anchor` runs in has none,
so it opens one: a tmux popup inside tmux, a split of the calling session on
iTerm2 — sideways on a wide window, below on a narrow one, and closed again when
you quit the editor. Anywhere
else, point `ANCHOR_EDITOR_LAUNCHER` at a script that takes the file path and
opens your editor on it, blocking until it closes.

`anchor` waits as long as you take. What ends the wait early is the pane closing
without reporting a result, which means the editor never got to save.

##### Picking a terminal editor

The job here is narrow: read one markdown document, change a few lines, quit.
There is no project to navigate and no build to run, so what suits it is an
editor you can drive without learning it first — a different question from which
editor you want for a day of code.

| Editor | Install | Why you'd pick it |
| --- | --- | --- |
| **[microsoft/edit](https://github.com/microsoft/edit)** — recommended | `brew install msedit` | No modes, and a menu bar that shows you the keys, so nothing has to be memorized before you can save. VS Code-style controls in one small binary. Installs as `edit`. |
| [helix](https://github.com/helix-editor/helix) | `brew install helix` | Modal, but selection-first: pick the text, then act on it, with a prompt that shows what each key does as you type it. Worth the learning if you'd also live in it — tree-sitter and LSP are built in. Runs as `hx`. |
| [amp](https://github.com/jmacdonald/amp) | see [amp.rs](https://amp.rs) | Vim's modal model, simplified. The comfortable pick if Vim already is. |
| [fresh](https://github.com/sinelaw/fresh) | see the repo | No modes and no configuration, with IDE features — LSP, multi-cursor, a command palette — if you want the editor to do more than take a draft. |

Point git at the one you pick:

```bash
git config --global core.editor edit
```

**Quitting without saving is not an abort.** An unchanged buffer comes back as
`approved`, which is what you want when the draft already reads correctly. To
stop the flow instead, empty the buffer.

### A backend per artifact

Which shape suits an artifact varies, so each skill has its own default —
decided by whether its review has a changeset in it.

| Skill | Default | Why |
|---|---|---|
| `commit`, `review` | `revdiff` | The subject is a changeset, and per-hunk annotation is what a diff viewer is for. |
| `prepare-review`, `issue`, `release` | `editor` | The subject is one drafted document. Its two sides are text against text, so a diff viewer marks every line as added and asks you to comment your way to a rewrite; the editor hands you the document and takes back what you saved. |

Either way you can name the other one:

```bash
git config anchor.reviewBackend revdiff        # every artifact in the TUI
git config anchor.commit.reviewBackend editor  # commit messages in $EDITOR
```

`anchor.commit.*`, `anchor.prepare-review.*`, `anchor.issue.*`, and
`anchor.release.*` cover the four artifacts `anchor` drafts. A per-skill key wins
in both directions, so an umbrella `editor` plus
`anchor.prepare-review.reviewBackend revdiff` edits everything but the CR
description.

Until you set one of them, the launch message says the tool was `anchor`'s pick
and names the key — the same hint the editor ladder prints, for the other half
of the choice.

**What `editor` does with the draft.** It opens the artifact in a buffer with the
change under review below a scissors line, the way `git commit --verbose` does:

```text
Add retry to checkout

The gateway drops idle connections, so the first call after …
------------------------ >8 ------------------------
Everything below this line is ignored. Save to accept the text above;
empty it to abort, and nothing this review gates will happen.
```

Whatever you save above that line **is** the artifact — `anchor` takes it
verbatim rather than re-drafting from it. Empty the buffer (or exit non-zero,
vim's `:cq`) and the flow halts with nothing committed, filed, or published.
Unlike `git commit`, lines beginning with `#` are kept: three of the four
artifacts are markdown, where `#` is a heading.

**When the tool isn't there.** `anchor` asks which backend a review can actually
open before it opens one — so a `revdiff` you haven't installed yet gets you the
diff viewer you *do* have, named in one line rather than discovered as a surprise
window. What substitutes is a *default*: a defaulted `editor` with nowhere to
open gives way to an installed viewer, since nobody asked for it. A backend you
named in the config is kept whether or not it can open, and reports what's
missing — handing you a diff viewer when you asked for the editor would answer a
question you didn't ask.

An editor carries one artifact, so it has nothing to show for a review that is a
diff on its own — `/anchor:commit`'s push-existing path, where there are
unpushed commits and no drafted message. That review halts and names the key to
change rather than passing a diff nobody saw.

### Forge-specific overrides (`cr` / `mr` / `pr`)

CR keys follow a prefix convention: `cr` is the forge-agnostic default, and `mr`
(GitLab) / `pr` (GitHub) override it when present. `prepare-review` picks the
forge by the `origin` remote, uses the matching `mr*` / `pr*` key if set, and
falls back to the `cr*` one otherwise. It governs both pairs — `crRules` /
`mrRules` / `prRules` and `crVerbosity` / `mrVerbosity` / `prVerbosity` — and
resolves them independently, so a `prVerbosity` with no `prRules` overrides the
length on GitHub and leaves the rules on `crRules`. Set just the `cr` key for one
setting everywhere; add `mr` / `pr` only where a forge needs something different.

## Examples

```bash
# Point anchor at your work tracker so a mentioned bare id expands to a full link
git config anchor.workTrackerBaseUri https://app.clickup.com/t/

# This team reviews fast — cover fewer topics, and write them shorter
git config anchor.reviewBudgetMins 5
git config anchor.crVerbosity 25

# A standing rule on GitHub PRs only
git config anchor.prRules "fill in the Risk & rollback section"
```

## Scope

`git config` layers the same way it does everywhere else — project-local overrides
global, global overrides system. Pick the layer by where the knob should apply:

```bash
git config anchor.reviewBudgetMins 10                                    # this project only (.git/config, untracked)
git config --global anchor.workTrackerBaseUri https://app.clickup.com/t/  # all your repos
```

## What configures what

`git config` knobs and forge templates shape **what goes in and where** — the
trailer, the checklist, the sections, the review budget. `anchor` brings **how
it's written** — the tone, the why-not-what, the criticality ordering — into
whatever shape you give it. The two compose; neither has to fight the other.
