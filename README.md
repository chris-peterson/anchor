# anchor

Git/forge skills for consistent and effective source control.

End-user docs: https://chris-peterson.github.io/anchor

An anchor holds a vessel fast against drift. Here it holds *work* fast: it takes
work-in-progress (tracked by [tack](https://github.com/chris-peterson/tack)),
runs it through review ([moor](https://github.com/chris-peterson/moor)), and
sets it down in source control — committed, described, and opened for
review on the forge.

## Repo layout

```text
.claude-plugin/plugin.json   plugin manifest
skills/preview/              /anchor:preview — open the in-flight diff for review (local / previous / full modes)
skills/commit/               /anchor:commit — stage, test, review, write the commit message
skills/prepare-review/       /anchor:prepare-review — rebase, draft the CR description, open/update the CR
skills/resolve-feedback/     /anchor:resolve-feedback — fetch CR feedback; fix / reply / resolve each thread to resolution
skills/pipeline/             /anchor:pipeline — work with a commit's forge pipeline; report state or watch until it settles
rules/                       ambient rules a SessionStart hook injects into every session
hooks/emit-rules.sh          the injecting hook (registered in hooks/hooks.json)
scripts/review-diff.sh       launch the configured difftool through its review sidecar; print the verdict on stdout
scripts/pipeline-status.sh   resolve / watch a commit's pipeline on the forge; print a normalized verdict on stdout
scripts/look-ahead.sh        unpushed-commit count (bash-analyzer-safe helper)
guides/                      load-bearing reference the skills/rules read at runtime (forge cookbook, description-vs-docs, changeset-scope)
docs/                        end-user docs site (docsify, GitHub Pages); skills/, rules/, guides/ are rendered in
```

## Optional integrations

The skills work standalone and light up further when these siblings are
installed (each degrades gracefully when absent):

- **[moor](https://github.com/chris-peterson/moor)** — the visual diff viewer the
  `commit` and `preview` skills launch. Absent → they fall back to `git difftool
  --dir-diff` with your configured difftool, asking whether to revise or proceed
  in place of moor's rejected-hunk feedback.
- **[tack](https://github.com/chris-peterson/tack)** — the WIP route tracker. Absent
  → CR-to-tack linking is skipped silently.

## Try the plugin locally

```bash
claude --plugin-dir .
```

Launches Claude Code with the working tree mounted as a plugin, so
`/anchor:commit`, `/anchor:prepare-review`, and `/anchor:preview` resolve.

## Docs

```bash
just docs
```

Runs `scripts/copy-skill-docs.sh` (syncs each `SKILL.md` and guide into `docs/`)
and serves the docsify site locally. Deployed to GitHub Pages on push to `main`
via `.github/workflows/deploy-docs.yml`.

## License

MIT
