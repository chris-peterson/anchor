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
| `anchor.reviewBudgetMins` | `git config anchor.reviewBudgetMins 10` | How many minutes of focused attention you expect this CR to get. It's an *input*, not a length cap: a tight budget (≈5) makes `prepare-review` lead with the essentials and cut asides hard; a generous one (≈30) keeps more supporting context and depth. It steers *what to include*, not the tone — a tight budget is no license for punchy or marketing framing. Unset behaves like ≈10. |
| `anchor.commitRules` | `git config anchor.commitRules "prefix the subject with the affected module"` | An extra rule layered onto `anchor`'s default commit-message rules, applied to every message it drafts. |
| `anchor.issueRules` | `git config anchor.issueRules "always include an acceptance-criteria checklist"` | An extra rule layered onto `anchor`'s default issue rules, applied to every issue the `issue` skill drafts. |
| `anchor.crRules` | `git config anchor.crRules "@-mention the on-call lead"` | An extra rule layered onto the default CR-description rules — the forge-agnostic default. See the `mr`/`pr` overrides below. |
| `anchor.mrRules` / `anchor.prRules` | `git config anchor.prRules "fill in the Risk & rollback section"` | Forge-specific overrides of `crRules`: `mrRules` applies on GitLab, `prRules` on GitHub. When set, the forge-specific key replaces `crRules` for that forge; otherwise `crRules` applies. |

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

### Forge-specific overrides (`cr` / `mr` / `pr`)

CR-rule keys follow a prefix convention: `cr` is the forge-agnostic default, and
`mr` (GitLab) / `pr` (GitHub) override it when present. `prepare-review` picks the
forge by the `origin` remote, uses the matching `mrRules` / `prRules` if set, and
falls back to `crRules` otherwise. Set just `crRules` for one rule everywhere; add
`mrRules` / `prRules` only where a forge needs something different.

## Examples

```bash
# Point anchor at your work tracker so a mentioned bare id expands to a full link
git config anchor.workTrackerBaseUri https://app.clickup.com/t/

# This team reviews fast — keep CR descriptions lean
git config anchor.reviewBudgetMins 5

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
