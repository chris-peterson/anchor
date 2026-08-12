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
| `anchor.reviewBackend` | `revdiff` | The terminal-native reviewer opens the diff; `moor` opens a GUI window instead, and `editor` opens the drafted text in your editor. The value is a preference among installed tools: with the named one absent, an installed viewer stands in, and with none installed the diff opens in git's configured difftool. |
| `anchor.<skill>.reviewBackend` | the umbrella key | A skill reviews in the backend above until you give that skill its own. |
| `anchor.reviewBudgetMins` | `10` | Descriptions are written for ten minutes of focused review — enough for the change and the topics around it. |
| `anchor.issueVerbosity` | `75` | Issue bodies run long: the people who pick the work up need the context in the issue. |
| `anchor.commitVerbosity` | `50` | Commit bodies run to the why plus the context the diff doesn't show. |
| `anchor.crVerbosity` | `25` | CR descriptions stay near the brief end — a reviewer on a deadline wants pointing, not explaining. |
| `anchor.releaseVerbosity` | `10` | Release notes run to each change as its effect on someone using the project, and stop. |
| `anchor.mrVerbosity` / `anchor.prVerbosity` | `anchor.crVerbosity` | No forge split — GitLab and GitHub get the same length until you set one. |
| `anchor.watchPipelineAfterPush` | `true` | Every push-side skill watches the pipeline that push started and reports it. |
| `anchor.<skill>.watchPipelineAfterPush` | the umbrella key | A skill follows the setting above until you give that skill its own. |
| `anchor.workTrackerBaseUri` | none | Mentioning a bare ticket id gets you no link — mention a full URL, or set this. |
| `anchor.commitRules` / `issueRules` / `crRules` / `mrRules` / `prRules` | none | The default commit, issue, and CR rules apply with nothing layered on. |
| `anchor.crTemplateRepo` | none | Template resolution stops at what the repo and the forge supply. |

Absent keys keep these; the skills never invent a value for a key you haven't
set.

## Keys

Keys use git's standard camelCase convention (like `init.defaultBranch` or
`commit.gpgSign`). git stores and matches them case-insensitively, so the case is
purely for readability. Defaults are in the table above rather than repeated in
each row.

| Key | Example | Effect |
|---|---|---|
| `anchor.workTrackerBaseUri` | `git config anchor.workTrackerBaseUri https://app.clickup.com/t/` | The base URL of your work tracker. When you mention a ticket, `commit` adds a `Refs:` trailer and `prepare-review` links it in the CR. See [Work-tracker references](#work-tracker-references). |
| `anchor.reviewBackend` | `git config anchor.reviewBackend moor` | Which review tool the skills launch: `revdiff`, `moor`, or `editor`. All three return the same normalized review verdict. `revdiff` is a terminal-native reviewer that also handles hg/jj repos, while `moor` additionally tracks which changes you have reviewed and round-trips an edited commit message; `revdiff` needs the revdiff plugin installed — `anchor` delegates to its terminal-overlay launcher to open the TUI — and `moor` reviews in a GUI window. `editor` is the other shape of the step: instead of commenting on the draft, you edit it. How the chosen tool renders the diff is its own knob, not an `anchor.*` key: see [Review-backend config](#review-backend-config) (per backend: [`revdiff`](#review-backend-config-revdiff), [`moor`](#review-backend-config-moor), [`editor`](#review-backend-config-editor)). |
| `anchor.<skill>.reviewBackend` | `git config anchor.commit.reviewBackend editor` | The same choice for one skill, overriding the umbrella key above. See [A backend per artifact](#a-backend-per-artifact). |
| `anchor.reviewBudgetMins` | `git config anchor.reviewBudgetMins 10` | How many minutes of focused attention you expect this CR to get. It's an *input*, not a length cap: a tight budget (≈5) makes `prepare-review` lead with the essentials and cut asides hard; a generous one (≈30) keeps more supporting context and depth. It steers *what to include*, not the tone — a tight budget is no license for punchy or marketing framing. For *how long* the result runs, see `crVerbosity` below and [Length knobs](#length-knobs). |
| `anchor.issueVerbosity` | `git config anchor.issueVerbosity 100` | Where an issue body sits between brevity and thoroughness. It sits highest of the four because the audience is the people who'll do the work, and what reads as detail to anyone else saves them a conversation. Below `100` the prose tightens in order — callouts, then the approach's explanation down to its load-bearing decisions, then Context's second paragraph. **Acceptance criteria are never abbreviated**: they say what done means, so they're the issue's floor the way the deep links are the CR's. |
| `anchor.commitVerbosity` | `git config anchor.commitVerbosity 25` | The same dial applied to the commit message body. Below `100` the body tightens in order — asides, then the decisions-and-alternatives prose, then the context paragraph — down to a floor of one sentence of *why*. The subject line's format rules and the `Refs:` trailer stand at every setting, and a trivial change still earns a subject-only message. |
| `anchor.crVerbosity` | `git config anchor.crVerbosity 50` | Where a CR description sits between brevity and thoroughness, as an integer from 1 to 100. It is not a word budget — nothing is counted or truncated; the number says how hard to lean on brevity when the two pull against each other. `100` is the [CR-description template](/templates/cr-description)'s full shape; below that the prose tightens, in the order the [verbosity guide](/guides/cr-verbosity) sets out. **It abbreviates sections, never removes them** — which sections a description has is the template's call, so one that meets its condition is present at every setting, down to its floor. It never cuts the *why* sentence or the Review guide's deep links, and it steers length only, never register. See the `mr`/`pr` overrides below. |
| `anchor.mrVerbosity` / `anchor.prVerbosity` | `git config anchor.prVerbosity 25` | Forge-specific overrides of `crVerbosity`: `mrVerbosity` applies on GitLab, `prVerbosity` on GitHub. When set, the forge-specific key replaces `crVerbosity` for that forge; otherwise `crVerbosity` applies. |
| `anchor.releaseVerbosity` | `git config anchor.releaseVerbosity 40` | The same dial applied to release notes. It sits lowest of the four: the audience is everyone using the project, and most of them are reading to find out whether this release affects them. Below `100` the notes shed rationale first, then the consequences a reader can infer, down to a floor of each change stated as its effect on someone using the project. **Every entry survives at every setting**, as do a breaking change's migration steps — the dial shortens entries, it doesn't drop them. |
| `anchor.commitRules` | `git config anchor.commitRules "prefix the subject with the affected module"` | An extra rule layered onto `anchor`'s default commit-message rules, applied to every message it drafts. |
| `anchor.issueRules` | `git config anchor.issueRules "always include an acceptance-criteria checklist"` | An extra rule layered onto `anchor`'s default issue rules, applied to every issue the `issue` skill drafts. |
| `anchor.crTemplateRepo` | `git config anchor.crTemplateRepo my-group/ci-templates` | A repo holding the CR template to use when neither this repo nor the forge's own inheritance supplies one. `prepare-review` reads it last, so it never overrides a template the team already ships. Give it as `group/project` on GitLab or `owner/repo` on GitHub; the template is looked for in that repo's usual locations. |
| `anchor.crRules` | `git config anchor.crRules "@-mention the on-call lead"` | An extra rule layered onto the default CR-description rules — the forge-agnostic default. See the `mr`/`pr` overrides below. |
| `anchor.mrRules` / `anchor.prRules` | `git config anchor.prRules "fill in the Risk & rollback section"` | Forge-specific overrides of `crRules`: `mrRules` applies on GitLab, `prRules` on GitHub. When set, the forge-specific key replaces `crRules` for that forge; otherwise `crRules` applies. |
| `anchor.watchPipelineAfterPush` | `git config anchor.watchPipelineAfterPush false` | Whether a skill that pushes then watches the pipeline that push triggered and reports it. Applies to every push-side skill (`commit`, `resolve-feedback`, `prepare-review`). See [Watching the pipeline after a push](#watching-the-pipeline-after-a-push). |
| `anchor.<skill>.watchPipelineAfterPush` | `git config anchor.prepare-review.watchPipelineAfterPush false` | The same knob for one skill, overriding the umbrella key above. |

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
opens the TUI through the revdiff plugin's terminal-overlay launcher, and the
overlays it uses (`tmux display-popup`, `kitty @ launch`, `zellij run`) spawn from
a long-running server process whose environment predates your shell rc; the
launcher forwards only `EDITOR` and `VISUAL` into it. So an
`export REVDIFF_WRAP=true` in `.zshrc` reaches a `revdiff` you start yourself and
can miss the one `anchor` opens. See
[revdiff's options](https://revdiff.com/docs.html#options) for the full list.

#### Review-backend config: `moor`

moor takes no presentation flags (it reads only the title and the sidecar path
`anchor` gives it), so there's nothing to configure on that side.

#### Review-backend config: `editor`

The `editor` backend uses whatever editor git uses, so the knob is git's own:

```bash
git config core.editor "code --wait"   # or set VISUAL / EDITOR
```

A GUI editor has to **block** — `--wait` on VS Code, `-w` on Sublime and
TextMate. Without it the editor returns the instant it opens and `anchor` reads
an untouched draft as one you approved.

A *terminal* editor needs a terminal, and the session `anchor` runs in has none,
so it opens one: a tmux popup inside tmux, an iTerm2 window on macOS. Anywhere
else, point `ANCHOR_EDITOR_LAUNCHER` at a script that takes the file path and
opens your editor on it, blocking until it closes. `ANCHOR_EDITOR_TIMEOUT`
(default 1800s) bounds how long `anchor` waits on a window that never closes.

`anchor` deliberately ignores a `GIT_EDITOR` set to `true` — the way an agent
harness keeps git from opening editors. Honoring it would open nothing, change
nothing, and read as approval.

### A backend per artifact

Which shape suits an artifact varies. A commit message is a natural editor
artifact — you usually know the sentence you want. A CR description whose deep
links want checking against the diff reads better in a diff viewer. So the
backend resolves per skill, the umbrella key setting the default:

```bash
git config anchor.reviewBackend revdiff        # diffs in the TUI
git config anchor.commit.reviewBackend editor  # commit messages in $EDITOR
```

`anchor.commit.*`, `anchor.prepare-review.*`, `anchor.issue.*`, and
`anchor.release.*` cover the four artifacts `anchor` drafts. A per-skill key wins
in both directions, so an umbrella `editor` plus
`anchor.prepare-review.reviewBackend revdiff` edits everything but the CR
description.

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

**When the tool you named isn't installed.** `anchor` asks which backend a review
can actually open before it opens one, and considers only installed tools — so a
`revdiff` you haven't installed yet gets you the diff viewer you *do* have, named
in one line rather than discovered as a surprise window. `editor` is never
substituted in: it edits one drafted artifact rather than showing a changeset, so
standing in for an absent diff viewer would answer a different question.

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
