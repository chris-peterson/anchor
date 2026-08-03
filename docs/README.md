# <img src="favicon.svg" alt="anchor" width="64" height="64" style="vertical-align: middle"> anchor

Consistency across the code-change lifecycle: issue, change request, review, release.

`anchor` is one skill per step: file the issue, commit the work after a
change-by-change review, open the change request, drive the review threads to
done, merge, publish the release. The commit messages, descriptions, and release
notes come out the same shape every time instead of reinvented per change.

```mermaid
%%{ init: { 'look': 'handDrawn' } }%%
flowchart TD
    Need["work to do"] -->|issue| Filed["issue on the forge"]
    Filed -->|commit| Pushed["reviewed and pushed"]
    Pushed -->|prepare-review| Open["change request open"]
    Open -->|resolve-feedback| Cleared["review threads cleared"]
    Cleared -->|merge| Landed["landed"]
    Landed -->|release| Shipped["published version"]
```

## In action

Tests pass, and `/anchor:commit` does the rest — staging, a why-first message,
and a code review in moor where a rejected change comes back as a concrete
edit, not a vague "looks off":

<div class="cw-session" data-cw-session="session"></div>

## Interface

| Surface | What it does |
|---|---|
| [`/anchor:commit`](/skills/commit) | Confirm the repo, run tests, stage everything, write a why-first commit message, review every change in the pending changeset, then — once the review is clean — commit and push |
| [`/anchor:prepare-review`](/skills/prepare-review) | Rebase on the default branch if behind, open a draft change request on the already-pushed branch (assigned to you, source branch set to delete on merge), and draft a description that points a reviewer at the lines where their judgment is worth the most |
| [`/anchor:resolve-feedback`](/skills/resolve-feedback) | Fetch the unresolved review threads on an open CR, triage each with you, then drive each to resolution — fix / reply / resolve |
| [`/anchor:merge`](/skills/merge) | Land an approved CR once its gates are green — waiting on the pipeline if needed — then return to the default branch and delete the merged branch |
| [`/anchor:release`](/skills/release) | Work out what has landed since the last release, recommend a semver bump, draft notes a *user* can read, and publish the way this repo publishes — a forge release where CI owns the bump, a bump commit where it doesn't |
| [`/anchor:pipeline`](/skills/pipeline) | Report a commit's forge pipeline state, or watch until it settles — passed, failed with the failed jobs named, or no pipeline |
| [`/anchor:issue`](/skills/issue) | Gather the *why*, the consumer, and acceptance criteria, then draft and file (or update) a forge issue — composing into the project's issue template when one exists |
| [`/anchor:issues`](/skills/issues) | List and rank the forge issues assigned to you so you can pick what to work on next — by soonest due date, then most recently updated |
| [Ambient rules](/ambient-rules) | A SessionStart hook injects the invariants that have to hold when no skill is invoked — how history may be rewritten, forge work going through `gh` / `glab`, and no AI attribution trailers |

The two skills you reach for most, in motion:

<div class="cw-session" data-cw-session="examples"></div>

## Quickstart

`anchor` drives the forge through its official CLI, so the skills that touch a
change request, issue, pipeline, or release (`prepare-review`,
`resolve-feedback`, `merge`, `release`, `pipeline`, `issue`, `issues`) need the
one for your `origin` remote installed and authenticated with read+write scope.
`commit` works without it. Install
[`gh`](https://cli.github.com) for GitHub or
[`glab`](https://gitlab.com/gitlab-org/cli#installation) for GitLab, then:

```bash
gh auth login      # GitHub remotes
glab auth login    # GitLab remotes
```

1. **Install the plugin.**

   ```bash
   claude plugin marketplace add chris-peterson/claude-marketplace
   claude plugin install anchor@chris-peterson
   ```

2. **Make some changes**, then commit with a reviewed, *why*-first message.
   `/anchor:commit` reviews the pending changeset, then commits and pushes once
   the review is clean:

   ```text
   /anchor:commit
   ```

3. **Open it for review.** On the already-pushed branch, draft the
   change-request description and open the draft CR:

   ```text
   /anchor:prepare-review
   ```

## Why these skills

The diff already shows *what* changed. The expensive, easily-skipped parts are
the ones a diff can't carry: a commit message that explains *why*, a code review
before the change leaves your machine, and a CR description that points a
reviewer at the lines where their attention pays off. `anchor` makes those the
path of least resistance.

- **commit** reviews the pending changeset before it commits, and feeds rejected
  changes back as concrete edits rather than vague "looks off" notes — nothing is
  committed until the review is clean.
- **prepare-review** writes for a reviewer who has never seen the system, leads
  with the *why*, and deep-links the critical path so a skim lands on what
  matters.

## Optional integrations

The skills run with nothing else installed. Each of these adds something when
present and is skipped when absent.

- **[moor](https://github.com/chris-peterson/moor)** — the default review
  backend, a keyboard-driven diff viewer the skills launch. Its `MOOR_CONTEXT`
  sidecar contract (the review-feedback channel) is defined in
  [moor's `SPEC.md`](https://github.com/chris-peterson/moor/blob/main/SPEC.md).
  Without moor, review falls back to `git difftool --dir-diff` with your
  configured difftool — you still get a visual review, and the skill asks whether
  to revise or proceed in place of moor's structured rejection feedback.
- **[revdiff](https://revdiff.com)** — an alternate review backend: a
  terminal-native diff reviewer (git, hg, and jj) selected with
  `git config anchor.reviewBackend revdiff`. It returns the same normalized
  review verdict as moor; its annotations come back ungraded, so the skill treats
  each as feedback to address and confirms the commit message itself. Because
  revdiff is a TUI, selecting it needs the revdiff plugin installed — `anchor` uses
  its terminal-overlay launcher to open the reviewer.
- **[tack](https://github.com/chris-peterson/tack)** — the work tracker. Naming a
  repo you aren't sitting in (`/anchor:commit payments-api`) resolves through
  tack's repo database, and when a tack route is bound to the session, `merge`
  records the CR against it and `release` attaches the release URL.

## Reference

- [What's new in 1.x](/whats-new) — the steps added since 0.x, and the three
  things that moved
- **Skills** — per-skill pages in the sidebar, sourced directly from each
  `SKILL.md`
- [Configuring `anchor`](/guides/configuring) — extend the commit and CR output
  with `git config anchor.*` keys and your forge's own PR/MR template
- [Forge cookbook](/guides/forge-cookbook) — the `gh` / `glab` invocations and
  etiquette the skills follow
- [Release models](/guides/release-models) — the four ways a repo publishes, and
  which one owns the version bump
- **Templates** — the output shapes the skills produce:
  [commit message](/templates/commit-message),
  [CR description](/templates/cr-description), and
  [issue description](/templates/issue-description)
