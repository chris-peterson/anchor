# Changelog

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
