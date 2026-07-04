# Changelog

## 0.18.0

### Features
- anchor's forge skills can now operate on a repo, branch, or CR that isn't the session's working directory. `prepare-review`, `commit`, and the pipeline/review helpers take `--repo <path>` (or `--worktree <path>`) and retarget every git/`gh`/`glab` call there — fixing the case where an MR meant for one repo was driven against the directory you happened to be in (and the `glab mr create -R` fork-mismatch 422 that came with it). For a repo you didn't start the session in, the work is isolated in a throwaway git worktree so it never disturbs that checkout; `prepare-review` also gains `--cr` to act on a CR that isn't the current branch's. Nothing changes when no target is given.
- Naming a target repo now resolves through tack's repo database instead of being guessed from the working directory. "File an issue against `customer-svc`" routes `customer-svc` to its real remote (and local checkout, when one is known) rather than the current directory's `origin` — no more filing against the wrong project or improvising an owner slug. Filing/updating an issue works with no local clone; the skills that need a working tree use the resolved checkout and ask for a path when there isn't one. tack stays optional — without it, resolution falls back to today's cwd behavior.
- `prepare-review` records ordering dependencies between successive change requests on the forge, not just in prose. On GitLab it sets an enforced "blocked by" dependency so the CRs can't merge out of order; on GitHub (which has no native cross-PR dependency) it writes a `Depends on #N` reference and says plainly that the ordering isn't enforced. Detection is conservative — it acts when you say a CR must land after another.

## 0.17.0

### Other
- `commit`'s squash-vs-new-commit decision moves into a `squash-check.sh` helper and is re-gated on one question — *is HEAD out for review?* A ready CR blocks the squash (a reviewer relies on the per-commit "changes since" diff); unpushed, draft-CR, and no-CR states allow it, with `--force-with-lease` when HEAD is pushed. This corrects the earlier count-based logic that suppressed squash whenever HEAD was pushed, wrongly withholding it on pushed branches with a draft CR or no CR — the case anchor's own history-rewrite rule says is safe to amend.
- `prepare-review`'s skill body is slimmed back under its size ceiling (~6.6k → ~5.0k words). The CR-description formatting technique — the data-shape → visualization menu, mermaid/before-after and screenshot recipes, prose conventions, and forge deep-link construction — moves to a new `cr-formatting` guide loaded on demand, and the Validation and heading-name guidance is deduped against the template that already owns it. Render-time traps stay in `markdown-gotchas`; no behavior change, the skill just stops loading its formatting reference into context on every invocation.

## 0.16.0

### Features
- The `/`-invoked skills (`commit`, `prepare-review`, `resolve-feedback`, `issue`, `pipeline`) are model-invocable again, and each `description` now carries a "when to use" hint so Claude reaches for the right one without being told. This restores the auto-invocation and trigger cues that 0.14.2–0.14.3 had trimmed for token cost — the descriptions stay lean but key off intent: `commit` off commit/push/checkpoint, `prepare-review` off opening an MR/PR or creating a review, `pipeline` off pipeline/build/CI/GitHub Actions, and so on.

### Other
- Decoupled from tack. `prepare-review` no longer calls `tack` to record the CR as a route's deliverable: tack already detects the CR URL from the `gh`/`glab` output through its own hook, so the explicit `tack find` / `deliverable` / `done` calls were redundant and coupled anchor to tack's CLI. anchor and tack now compose through the shared session — neither plugin references the other. The close-the-loop "mark done" step is left to a future merge/release skill. tack is dropped from the suite dependencies and the optional-integrations docs.

## 0.15.0

### Features
- New `omit-attribution-trailers` ambient rule. The default Claude Code harness appends a `Co-Authored-By: Claude` trailer to commits and ends PR/MR bodies with a "Generated with Claude Code" line. anchor produces commits, change requests, and issues, so it now injects a rule countering those defaults — keeping its git artifacts free of tooling attribution, with the `Refs:` work-tracker link the only trailer it adds. The commit-message template's Trailers section and the ambient-rules page point at the new rule.

## 0.14.3

### Other
- The `/`-invoked skills (`commit`, `issue`, `prepare-review`, `resolve-feedback`, `pipeline`) are now marked `disable-model-invocation`, dropping their descriptions from every session's always-resident context. They stay available via `/` and in the menu; Claude just no longer auto-loads them.

## 0.14.2

### Other
- Trimmed skill `description` frontmatter to cut the always-resident context cost each skill carries on every turn. The `/`-invoked skills (`commit`, `issue`, `prepare-review`, `resolve-feedback`) no longer list redundant trigger phrases; `pipeline` keeps only the natural-language cues ("is the build green", "did my pipeline pass", "notify me when ci passes").

## 0.14.1

### Other
- Markdown-rendering gotchas — character escaping (`~`, `$`, `_`, `*`), nested code fences, mermaid blocks, collapsible `<details>`, and tables under list items — are now collected in a single `markdown-gotchas` guide, referenced from `/anchor:prepare-review`, `/anchor:issue`, and the forge cookbook instead of restated in each.
- Documents a tilde-strikethrough trap: GFM strikes text wrapped in one or two tildes, so two `~`-prefixed values in one paragraph (for example two approximate costs) can pair into an unintended strike.

## 0.14.0

### Features
- `/anchor:prepare-review` no longer dead-ends when run with finished-but-uncommitted work. It detects that nothing is committed ahead of the default branch and chains into `/anchor:commit`, then resumes — instead of surfacing the forge's raw "could not find any commits between" error.

### Other
- Sharpened the change-request description guidance in prepare-review, encoding recurring traps (re-describing the diff in prose, two GitLab-markdown pitfalls) so generated descriptions stay focused on *why* a change exists.

## 0.13.0

`/anchor:commit` no longer suggests rewriting a commit you didn't author.

- **Author guard on squash/amend.** The squash-vs-new-commit decision keyed only on push state and the CR's draft flag — both assuming an unpushed commit is your own. Since `--amend` and squash rewrite HEAD in place, `/anchor:commit` now compares HEAD's author email to your `user.email` and, on a mismatch, drops the squash option and offers only a new commit, so it never proposes overwriting someone else's commit and authorship. The `rewrite-history-through-anchor` rule's "unpushed commits are yours" guidance is refined to match.

## 0.12.0

Three skill changes: `/anchor:issue` now guards against duplicates, and the `preview` skill folds into `/anchor:commit`.

- **`/anchor:issue` checks for similar issues before filing.** On the create path, it searches the forge (open *and* closed) for issues that already cover the need and surfaces any matches; picking one reroutes into the existing update path instead of filing a duplicate.
- **`preview` folds into `/anchor:commit --preview`.** The standalone `preview` skill is removed. `/anchor:commit --preview` opens the working-tree diff in the difftool for review without committing — the look-before-you-commit pass, same review channel, no commit.
- **`--preview cr` reviews the whole change request.** `/anchor:commit --preview cr` (or `mr` / `pr`) opens the full branch-vs-default-branch diff, the way a reviewer sees the CR — a self-review of the complete changeset before opening or updating it.

## 0.11.0

Build and release plumbing for the plugin — no skill behavior changes.

- **Canonical `plugin.yml` descriptor.** Plugin metadata lives in `plugin.yml` and is projected into `.claude-plugin/plugin.json` and the marketplace SPA by generation scripts, so there's a single source to edit instead of hand-synced JSON.
- **Hub/spoke marketplace model.** anchor ships as a spoke: its docs site renders the live session preview, and the marketplace hub links into the spoke for the detail view.
- **Release-on-publish workflow.** Publishing a GitHub Release (`vX.Y.Z`) bumps the version, regenerates `plugin.json`, prepends the release notes to `CHANGELOG.md`, and notifies the marketplace.

## 0.10.1

### Fixes

- `/anchor:prepare-review` now fails loudly if it opens a draft change
  request but can't read it back from the forge, instead of silently
  continuing without the review deep links.

### Other

- `/anchor:prepare-review` is quieter: it no longer narrates its internal
  steps — forge detection, ahead/behind counts, the anti-recency
  disposition, "here's what I just did" recaps — while preparing a review.
  Setting up the change request (detecting the forge, opening the draft CR,
  checking branch state, reading the template and config) now runs as one
  step rather than a play-by-play.

## 0.10.0

### Features

- New [`/anchor:issue`](https://chris-peterson.github.io/anchor/#/skills/issue)
  skill drafts and files (or updates) a forge issue. Since an issue describes
  work *to be done* rather than a diff, it gathers the *why*, the consumer, and
  the acceptance criteria up front, then writes for a reader unfamiliar with the
  area. Issue conventions vary more between teams than commits or CRs, so
  anchor's default shape stays basic and the skill composes into a project's own
  template when one exists — `.gitlab/issue_templates/*.md` or
  `.github/ISSUE_TEMPLATE/*.md`. A new
  [`issue-description`](https://chris-peterson.github.io/anchor/#/templates/issue-description)
  template documents the shape, and `anchor.issueRules` layers a standing rule
  onto every issue (see the
  [configuring guide](https://chris-peterson.github.io/anchor/#/guides/configuring)).

## 0.9.0

### Features

- anchor is now configurable without committing an anchor-specific file to your
  repo. The base — tone, why-not-what discipline, criticality ordering — stays
  baked in; you extend *around* it through two surfaces:
  - **`git config anchor.*` keys** — `commit` and `prepare-review` read
    `anchor.workTrackerBaseUri` (turns a mentioned ticket — a full URL, or a
    bare id expanded against the base — into a `Refs:` trailer / CR link),
    `anchor.reviewBudgetMins` (the reviewer focus time you expect, steering
    brevity and depth), and `anchor.commitRules` / `anchor.crRules` for extra
    rules layered onto the defaults (`mrRules` / `prRules` override `crRules` per
    forge). Project-local lives in `.git/config` (untracked); `--global` spans
    repos.
  - **Forge-native CR templates** — `prepare-review` detects
    `.gitlab/merge_request_templates/*.md` / `.github/pull_request_template.md`
    and composes anchor's prose into the team's scaffolding instead of replacing
    it.

  New guide [`configuring.md`](https://chris-peterson.github.io/anchor/#/guides/configuring)
  documents the key set and the extension model.

- The output shapes the skills produce are now documented artifacts under a new
  `templates/` tree, rendered into the docs site and cross-linked to the
  configurable items: [commit message](https://chris-peterson.github.io/anchor/#/templates/commit-message)
  (the cbea.ms rules + the `Refs:` trailer) and
  [CR description](https://chris-peterson.github.io/anchor/#/templates/cr-description)
  (the section shape + the forge-template probing rules). The CR template moved
  out of `skills/prepare-review/` into `templates/`; both skills now read their
  shape from `templates/`.

### Fixes

- Review feedback from moor surfaces correctly again. moor consolidated its
  sidecar output into a single `comments[]` array (each `fix-now` / `fix-later`
  / `consider`); `commit`, `preview`, and `prepare-review` now read it, so a
  fix-now review shows the actual comments and line ranges instead of a bare
  "rejected hunks detected" with no detail.

### Other

- The forge cookbook clarifies that `--hostname` is a `glab api`-only flag —
  porcelain subcommands like `glab mr view` reject it.

## 0.8.0

### Features

- `/anchor:pipeline` can now track a single named job, not just the whole
  pipeline. Pass `--job <name>` to `scripts/pipeline-status.sh` (with `--watch`
  to poll until that job settles) and it resolves the commit's pipeline, finds
  the job by name — latest attempt if retried — and reports its state via
  `PIPELINE_JOB_STATE` / `PIPELINE_JOB_URL`, with the parent pipeline as context.
  Pass `--pipeline <id>` to target a pipeline directly (e.g. from a pasted URL)
  and skip commit→pipeline resolution. This replaces the hand-written
  `glab api .../jobs | filter-by-name | until … sleep` loop that watching one
  gating job (a Terraform plan, say) otherwise required.

## 0.7.0

### Features

- New skill `/anchor:pipeline` — work with the forge pipeline for a commit.
  By default a one-shot read of its latest state; ask to watch and it polls until
  the pipeline settles, then reports passed (with the pipeline URL), failed (with
  the list of failed jobs, each linked), or no pipeline for the commit. Backs both
  *"what's the pipeline doing right now"* and *"I pushed, tell me when it's done"*
  with one callable unit, so a release workflow no longer hand-rolls the poll loop.
  New `scripts/pipeline-status.sh` does the forge-agnostic work — picks `gh`/GitHub
  or `glab`/GitLab by the `origin` remote, resolves the pipeline for the current
  branch at HEAD's commit, and either reports once (default) or watches (background
  `until` loop, `--watch`) to a terminal state. The GitLab path reads pipeline and
  job status through `glab api projects/:fullpath/...` (the forge cookbook's idiom);
  the GitHub path uses `gh run list` / `gh run view`. Pass `--branch` / `--sha` to
  target an explicit ref, `--interval` / `--timeout` to tune the watch cadence and
  ceiling.

### Changed

- Renamed the `/anchor:address-feedback` skill to `/anchor:resolve-feedback`.
  The name now states the goal — every review thread ends *resolved* (fixed,
  answered, or marked resolved), not merely addressed. Behavior is unchanged;
  the old triggers (`address feedback`, `respond to review`, a pasted CR URL)
  still match, alongside the new `resolve feedback`. Update any saved references
  to the old command name.
- `/anchor:prepare-review` auto-opens the draft CR when none is open, instead of
  prompting `[yes / web / skip-deep-links]` first. A draft CR is non-disruptive
  — it requests no review, the branch push already triggered any branch-level
  CI, and self-assign notifies only the author — so the common case (no CR yet →
  open one) just happens, and drafting proceeds against the freshly-opened CR.
  The creation defaults are unchanged (draft, self-assigned, delete-source-branch).
  Auth failures at create still fail fast (surface 401/403, ask to refresh — no
  silent URL-free fallback), and the URL-free (`skip-deep-links`) and open-in-web
  paths remain as non-default escapes the user can invoke rather than an up-front
  prompt. This makes `prepare-review` the single home for CR creation now that
  the ai-sdlc ship-it skill delegates all CR creation to it.

### Other

- Reworded the plugin description and tagline to "Git/forge skills for
  consistent and effective source control" (across `plugin.json`, both READMEs,
  and the docs-site meta tag).
- The forge cookbook gains a **CI / pipelines** section — the pipeline vs
  workflow-run/Actions terminology, the canonical `gh run` / `glab api
  .../pipelines` invocations for resolving a commit's pipeline and its failed
  jobs, and the GitHub-vs-GitLab status-vocabulary difference. The `/anchor:pipeline`
  skill references it for the forge calls its helper makes.

## 0.6.0

### Features

- `/anchor:preview` gains three named review modes, picked by a chain of
  responsibility so it always has something useful to open: **local changes**
  (working tree vs the last commit — the default when the tree is dirty),
  **previous changeset** (the last commit vs its parent — the fallback when the
  tree is clean), and **full diff** (the whole branch vs the default branch,
  the way a reviewer sees a CR — pass `cr` / `mr` / `pr`). `scripts/review-diff.sh`
  grows matching `--local` / `--previous` / `--full` flags, each with a
  mode-specific moor header.
- New bundled guide `guides/changeset-scope.md` — once a change enters review,
  keep edits within the changeset's existing scope and be surgical; the review
  phase wants minimal churn, down to individual lines. Don't pull unrelated
  pre-existing code into the diff even when a rejected hunk or a direct ask seems
  to point at it — surface the scope expansion and confirm (fold in, or separate
  change?) first. Referenced just-in-time from `address-feedback` (fixing
  rejected hunks, "while you're in there" asks) and `commit` (the rejected-hunk
  fix loop).

### Changed

- Load-bearing guides move out of `docs/` into a top-level `guides/` directory
  (`forge-cookbook.md`, `description-vs-docs.md`, `changeset-scope.md`). Skills
  and rules read them at runtime via `${CLAUDE_PLUGIN_ROOT}/guides/<name>.md`,
  so they belong with the source — not in the rendered docs site.
  `copy-skill-docs.sh` renders them into `docs/guides/` (gitignored) alongside
  the skill and rule pages, leaving `docs/` a pure render target.

## 0.5.0

### Features

- The `commit` and `preview` skills run their visual-diff review in a single
  launch-and-read. `scripts/review-diff.sh` gains a `--commit` mode that works
  out the review range from the unpushed-commit count itself and prints the
  verdict (`REVIEW_VERDICT`, plus `REVIEW_OUTPUT` carrying any rejected hunks)
  on its own stdout — so the skill no longer runs a separate range probe and
  then opens and parses a sidecar file.

### Changed

- The `commit`, `preview`, and `address-feedback` skills no longer narrate
  their internal setup and orchestration back to you — range probes, "launching
  in the background", sidecar reads. They run those steps quietly and surface
  only what you act on: the resolved repo, test results, the drafted message,
  and the review verdict.
- Renamed `scripts/moor-review.sh` → `scripts/review-diff.sh`. It drives
  whatever difftool git is configured with — moor when installed, any other
  difftool otherwise — so the name no longer implies moor. The verdict it prints
  uses `REVIEW_VERDICT` / `REVIEW_OUTPUT`; the `MOOR_CONTEXT` sidecar env var
  keeps its name, since that's the contract moor reads.
- Renamed `scripts/ahead-count.sh` → `scripts/look-ahead.sh` (verb-noun, matching
  `review-diff.sh`). It still prints the unpushed-commit count and stays the
  bash-analyzer-safe helper for the `@{u}` range that `commit` uses to decide
  the no-changes stop and the squash-vs-new-commit option.

## 0.4.0

### Features

- `prepare-review` treats editing an open CR's description as a revision: it
  pulls the current description to a temp file, presents the draft as a `diff`
  against that baseline (rather than re-printing the whole body), and on the
  **Edit** disposition opens a one-off moor review of current vs. draft so the
  user rejects specific hunks with a reason on each. The reasons come back
  through the `MOOR_CONTEXT` sidecar (`output.rejections`) and fold into the
  next revision. When `moor` isn't installed, Edit falls back to a chat
  exchange.
- `scripts/moor-review.sh` gains a domain-agnostic `--files <left> <right>
  [--title <t>] [--detail label=value]...` mode for reviewing two arbitrary
  paths instead of a git range, so any flow can route directed feedback
  (rejected hunks with reasons) through moor's sidecar contract.

## 0.3.0

### Features

- New skill `/anchor:address-feedback` — fetch the unresolved review threads
  on an open CR, triage each with the author (fix / reply / resolve / defer /
  skip), then apply: follow-up commits citing the thread, terse replies into
  the existing threads, resolution only where the disposition called for it.
  The forge cookbook gains the thread operations (list unresolved, reply,
  resolve) for both forges.
- New bundled guide `docs/description-vs-docs.md` — when CR-description
  content earns promotion to repo docs (author-flagged, very high bar) and
  how to adapt it for a long-lived home. Referenced just-in-time from
  `prepare-review` and `address-feedback`.
- The plugin ships its ambient rules: a SessionStart hook injects `rules/*.md`
  into the session context (re-injected after compaction), so anchor's routing
  holds even when no skill is invoked:
  - `rewrite-history-through-anchor` — amend/squash/rebase/force-push route
    through `/anchor:commit`; for rewrites beyond the skill, gate on push
    state and the CR's draft flag (unpushed → rewrite freely; pushed + draft
    → mutable history is still the norm; pushed + ready → follow-up commits,
    force-push only with explicit sign-off).
  - `use-forge-clis` — drive forge operations through `gh`/`glab`, passing
    multi-line bodies by file; deeper invocations come from the bundled forge
    cookbook.
- The moor review header now identifies the `repo` and `branch` in both
  flows, and previews add the commit the working tree sits on — so
  back-to-back reviews across repos are unambiguous.
- `prepare-review` and `commit` gate force-push ceremony on the CR's draft
  flag (declared author intent) instead of inferred review activity (note
  counts, reviewer lists), which misreports in both directions. A draft CR
  rebases and force-pushes with lease without ceremony; a ready CR asks
  first, with engagement signals as advisory context.

### Fixes

- GitLab assignment in the cookbook and `prepare-review` used
  `-F "assignee_ids[]=<id>"`, which `glab api` silently drops (no
  `key[]=value` array syntax, unlike `gh api`) — creates landed unassigned
  with no error. API-form creates now assign via a follow-up
  `glab mr/issue update --assignee <username>`, and the cookbook documents
  the array-encoding trap alongside the nested-object one.
- `prepare-review`'s canonical `glab mr create` gains `--yes`; without it
  the command stalls on an interactive submission prompt.

## 0.2.0

### Features

- `commit` and `preview` now fall back to `git difftool --dir-diff` with your
  configured difftool when `moor` isn't installed, so you still get a visual
  review instead of having the step skipped. With no `moor` sidecar to capture a
  verdict, the skill asks whether to revise or proceed — a stand-in for moor's
  rejected-hunk feedback.
- `prepare-review` reads its change-request description structure from an
  editable `cr-description-template.md`, so you can tune the description shape
  without editing the skill's procedure.
- For shared-component changes, `prepare-review` asks what validation looks like
  and records your answer, rather than emitting a guessed checklist row.
