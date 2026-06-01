# Changelog

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
