# Guides

The skills carry a change from one state to the next. The guides are the
standing judgment they apply along the way: how a commit message reads, how long
a CR description runs, what a review does when the tool came back without a
verdict, which `gh` or `glab` invocation is the right one.

They ship inside the plugin and are read at runtime. A skill loads the guide for
the decision in front of it, at the moment it reaches that decision, which is why
the same voice comes out of `anchor:commit` and `anchor:issue` even though
neither skill restates it. The [templates](/templates/commit-message) own the
*shape* of each artifact, which sections in what order; the guides own the
judgment applied while filling it.

## Prose

`anchor` writes commit messages, CR descriptions, issue bodies, and release
notes under your name. These guides are what makes them read the way they do.

| Guide | What it settles | Read by |
|---|---|---|
| [Loaded framing](/guides/loaded-framing) | The tone floor: temporal blame, hyperbole, self-congratulation, and defensive softeners come out; the factual claim stays | `commit`, `prepare-review`, `issue`, `release`, `review` |
| [CR verbosity, calibrated](/guides/cr-verbosity) | Where a description sits between brevity and thoroughness, shown as one real changeset drafted across the `anchor.crVerbosity` range | `prepare-review` |
| [CR formatting](/guides/cr-formatting) | Which visualization fits which data shape, plus the mermaid, screenshot, and skim-readability technique to render it | `prepare-review` |
| [Markdown gotchas](/guides/markdown-gotchas) | The characters and constructs that render wrong once a forge has its way with them, and what neutralizes each | `prepare-review`, `issue`, `release` |
| [Description vs. docs](/guides/description-vs-docs) | Whether explanatory content belongs to this review or to the repo's docs, and the bar for promoting it | `prepare-review`, `resolve-feedback` |

## Review

What a change under review is graded against, and what happens when the grading
doesn't arrive.

| Guide | What it settles | Read by |
|---|---|---|
| [When the review tool didn't grade it](/guides/review-fallback) | What an ungraded change gets instead of a *"you saw the diff, approve?"* prompt | `commit`, `prepare-review`, `review`, `issue`, `release` |
| [Reading a reviewer's edits](/guides/reviewer-edits) | How to read feedback a difftool leaves as edits in the working tree rather than as annotations | `commit`, `prepare-review`, `review`, `issue`, `release` |
| [Staying in changeset scope](/guides/changeset-scope) | How far a fix may reach when a comment lands next to pre-existing code the diff doesn't own | `commit`, `resolve-feedback` |

## Mechanics

The deterministic half: which command to run, which path to take, and how much
to say while doing it.

| Guide | What it settles | Read by |
|---|---|---|
| [Host runtime](/guides/host-runtime) | How bundled paths, questions, background commands, and skill handoffs map across Claude Code and Codex | every skill |
| [Configuring `anchor`](/guides/configuring) | Every `git config anchor.*` key, and how your forge's own CR template composes with `anchor`'s voice | `commit`, `prepare-review`, `issue` |
| [Forge cookbook](/guides/forge-cookbook) | The canonical `gh` and `glab` invocations, and the places the two CLIs diverge | every skill that touches the forge |
| [Release models](/guides/release-models) | Who owns the version bump, and the publish step each model takes | `release` |
| [Temp paths a caller can grant](/guides/temp-paths) | The temp-file form that stays inside a caller's permission grant on every platform | `commit`, `issue`, `resolve-feedback` |
| [Execute quietly](/guides/execute-quietly) | What a skill puts on screen, and what it reads and acts on without saying | every skill |

## Changing what comes out

A guide is `anchor`'s default, not a setting. To move the output for your repo
or your account, reach for [configuring `anchor`](/guides/configuring): the
verbosity dial, the review tool, the commit and CR knobs, and your forge's own
template all sit there, and none of them commit an `anchor`-specific file to your
repo.
