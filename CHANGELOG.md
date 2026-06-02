# Changelog

## 0.3.0

### Features

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
