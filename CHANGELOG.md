# Changelog

## Unreleased

### Changed

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
