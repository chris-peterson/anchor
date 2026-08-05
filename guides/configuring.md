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

## Keys

Keys use git's standard camelCase convention (like `init.defaultBranch` or
`commit.gpgSign`). git stores and matches them case-insensitively, so the case is
purely for readability.

| Key | Example | Effect |
|---|---|---|
| `anchor.workTrackerBaseUri` | `git config anchor.workTrackerBaseUri https://app.clickup.com/t/` | The base URL of your work tracker. When you mention a ticket, `commit` adds a `Refs:` trailer and `prepare-review` links it in the CR. See [Work-tracker references](#work-tracker-references). |
| `anchor.reviewBackend` | `git config anchor.reviewBackend revdiff` | Which visual-review tool the skills launch: `moor` (default) or `revdiff`. Both return the same normalized review verdict; `revdiff` is a terminal-native reviewer that also handles hg/jj repos, while `moor` additionally grades comments, tracks which changes you have reviewed, and round-trips an edited commit message. Selecting `revdiff` needs the revdiff plugin installed — `anchor` delegates to its terminal-overlay launcher to open the TUI. How the chosen tool renders the diff is its own knob, not an `anchor.*` key: see [Review-backend config](#review-backend-config) (per backend: [`revdiff`](#review-backend-config-revdiff), [`moor`](#review-backend-config-moor)). |
| `anchor.reviewBudgetMins` | `git config anchor.reviewBudgetMins 10` | How many minutes of focused attention you expect this CR to get. It's an *input*, not a length cap: a tight budget (≈5) makes `prepare-review` lead with the essentials and cut asides hard; a generous one (≈30) keeps more supporting context and depth. It steers *what to include*, not the tone — a tight budget is no license for punchy or marketing framing. Unset behaves like ≈10. For *how long* the result runs, see `crVerbosity` below and [Two length knobs](#two-length-knobs). |
| `anchor.crVerbosity` | `git config anchor.crVerbosity 25` | Where a CR description sits between brevity and thoroughness, as an integer from 1 to 100. Unset behaves as `50`. It is not a word budget — nothing is counted or truncated; the number says how hard to lean on brevity when the two pull against each other. `100` is the [CR-description template](/templates/cr-description)'s full shape; below that the prose tightens, in the order the [verbosity guide](/guides/cr-verbosity) sets out. **It abbreviates sections, never removes them** — which sections a description has is the template's call, so one that meets its condition is present at every setting, down to its floor. It never cuts the *why* sentence or the Review guide's deep links, and it steers length only, never register. See the `mr`/`pr` overrides below. |
| `anchor.mrVerbosity` / `anchor.prVerbosity` | `git config anchor.prVerbosity 25` | Forge-specific overrides of `crVerbosity`: `mrVerbosity` applies on GitLab, `prVerbosity` on GitHub. When set, the forge-specific key replaces `crVerbosity` for that forge; otherwise `crVerbosity` applies. |
| `anchor.commitRules` | `git config anchor.commitRules "prefix the subject with the affected module"` | An extra rule layered onto `anchor`'s default commit-message rules, applied to every message it drafts. |
| `anchor.issueRules` | `git config anchor.issueRules "always include an acceptance-criteria checklist"` | An extra rule layered onto `anchor`'s default issue rules, applied to every issue the `issue` skill drafts. |
| `anchor.crRules` | `git config anchor.crRules "@-mention the on-call lead"` | An extra rule layered onto the default CR-description rules — the forge-agnostic default. See the `mr`/`pr` overrides below. |
| `anchor.mrRules` / `anchor.prRules` | `git config anchor.prRules "fill in the Risk & rollback section"` | Forge-specific overrides of `crRules`: `mrRules` applies on GitLab, `prRules` on GitHub. When set, the forge-specific key replaces `crRules` for that forge; otherwise `crRules` applies. |
| `anchor.watchPipelineAfterPush` | `git config anchor.watchPipelineAfterPush false` | Whether a skill that pushes then watches the pipeline that push triggered and reports it. On by default, for every push-side skill (`commit`, `resolve-feedback`, `prepare-review`). See [Watching the pipeline after a push](#watching-the-pipeline-after-a-push). |
| `anchor.<skill>.watchPipelineAfterPush` | `git config anchor.prepare-review.watchPipelineAfterPush false` | The same knob for one skill, overriding the umbrella key above. |

Absent keys fall back to `anchor`'s defaults; the skills never invent a value for
a key you haven't set.

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

### Two length knobs

`reviewBudgetMins` and `crVerbosity` both make a description shorter, and they do
it on different axes — which is why turning one down is not a substitute for the
other:

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
