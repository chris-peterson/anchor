# anchor

A Claude Code plugin covering the code-change lifecycle — filing issues,
committing with why-first messages, opening and describing change requests,
resolving review feedback, reporting pipelines, merging, releasing — the same
way on GitHub and on GitLab. What each skill does for a *user* lives on the docs
site (https://chris-peterson.github.io/anchor); this file is for working on the
plugin itself.

`SPEC.md` is the requirement source of record and `STATUS.md` is its coverage
ledger. A change to behavior updates the requirement and the ledger in the same
commit, not as a follow-up.

## Commands

```bash
just generate       # project source into plugin.json, hooks.json, describe, and docs/
just docs           # render the docs site and serve it locally

just test           # every suite this platform runs, via tests/run-all.sh
bash tests/<name>.test.sh                                  # one suite
shellcheck hooks/*.sh scripts/*.sh scripts/review/*.sh tests/*.sh
```

`tests/run-all.sh` discovers `tests/*.test.sh`, so a new suite needs no wiring in
the justfile or `.github/workflows/test.yml` — CI is one job running that script
across an ubuntu / macOS / Windows matrix. A suite declares where it is expected
to hold with a `# ci-platforms:` line in its own header; absent one it runs on
linux and macos. Windows is opt-in, and the suites that claim it are the ones
whose subject *is* the platform difference — which `mktemp` the shell resolves,
whether the host ships `sha1sum`.

## Layout

```text
plugin.yml                canonical descriptor — manifest, marketplace entry, docs previews
skills/<name>/SKILL.md    one skill per lifecycle step; the prompt is the implementation
rules/                    ambient rules injected into every session by hooks/emit-rules.sh
scripts/                  the deterministic helpers the skills shell out to
scripts/lib/              sourced-only helpers (context resolution, portable temp paths)
scripts/review/           per-backend review adapters (revdiff, editor)
guides/                   reference the skills and rules read at runtime
templates/                the output shapes the skills produce, read at runtime
tests/                    bash suites, one per script under test
SPEC.md / STATUS.md       requirements and their coverage
docs/                     docsify site; only README, _sidebar, ambient-rules, whats-new, favicon are source
```

`.claude-plugin/plugin.json`, `hooks/hooks.json`, `plugin.yml`'s `suite.describe`
block, and most of `docs/` are **generated** by
[shipyard](https://github.com/chris-peterson/shipyard) from the sources above.
Never hand-edit a generated file; edit its source and let the projection follow.

The projection job in `.github/workflows/project.yml` is that writer: it runs
`shipyard generate` on every push and commits the result to the branch, so a
committed artifact matches its source at all times and the diff a reviewer
approves is what lands. `just generate` runs the same projectors locally when
you want to see the result before pushing.

Releases are dispatched, not tagged by hand: run the **Release** workflow with a
bump level, and shipyard derives the version from `plugin.yml`, retitles
`CHANGELOG.md`'s `## Unreleased` section, commits, tags that commit, and
publishes. Write the notes into `## Unreleased` first — reading what landed is
what picks the level.

## Conventions

- **Bash, no third-party dependencies.** The scripts run wherever the user's
  session runs, including a Windows Git Bash. Portability claims get a CI matrix
  job rather than a comment — `scripts/lib/tmpfile.sh` exists because GNU and BSD
  `mktemp` disagree about where an `XXXXXX` run may sit in a template.
- **shellcheck is a zero-finding baseline** at the default severity, so any new
  finding fails CI. `scripts/lib/*.sh` is sourced-only and lints *through* its
  callers; `scripts/review/*.sh` lints standalone because the dispatcher builds
  the adapter path at run time and `external-sources` can't reach it.
- **The script decides facts; the skill decides judgment.** Whether HEAD is out
  for review, what the pipeline returned, which release model a repo follows —
  deterministic, and it belongs in `scripts/`. What the change is *for*, and
  whether the drafted prose says it, is the model's half and belongs in the
  `SKILL.md`.
- **A helper's `KEY=value` output is input to the next decision, not output to
  the user.** Skills execute quietly: run the step, read the result, move on. The
  discipline is in `guides/execute-quietly.md` and the skills link to it rather
  than restating it.
- **Both forges, always.** A behavior added for `gh` needs its `glab` half in the
  same change, and the invocation gaps between them are recorded in
  `guides/forge-cookbook.md` — read it before re-deriving a command.
- **Nothing publishes under the user's name without their approval of the exact
  text** (CONFIRM-01..06). A plan describing what the message will say is not the
  message; the artifact itself has to reach the user before it lands.
- **No AI attribution trailers** in anything the plugin authors — the commit
  author and CR author fields already record it.

## Glossary

- **Forge** — GitHub or GitLab, selected by the `origin` remote, which in turn
  selects the CLI (`gh` / `glab`).
- **CR (change request)** — a pull request on GitHub, a merge request on GitLab.
  The neutral term exists so a skill can be written once.
- **Ambient rule** — standing guidance a `SessionStart` hook injects into every
  session, whether or not a skill is invoked.
- **Review contract** — the tool-agnostic result `scripts/review-diff.sh`
  returns: a verdict (`approved` · `changes-requested` · `incomplete` ·
  `no-verdict`) plus normalized comments and capabilities, produced from a
  backend's native output by its adapter. An absent or unparseable verdict is
  `no-verdict` and halts the flow — it is never read as approval.
- **Squash gate** — the deterministic "is HEAD out for review?" decision in
  `scripts/squash-check.sh` that governs amend-vs-new-commit.
- **Deep link** — a line-anchored forge URL in a CR description that lands a
  reviewer on the relevant change rather than the top of the diff.
- **Release model** — who owns the version bump: a CI workflow triggered by a
  published release or tag push, a bump commit in the repo, or nobody. Resolved
  by `scripts/release-recon.sh`; a wrong read collides with the workflow's own
  commit, which is why it is established before anything is drafted. This repo's
  own shape is `dispatch-triggered`: the **Release** workflow owns the bump, so
  `/anchor:release` commits the notes and dispatches rather than editing
  `plugin.yml`.
