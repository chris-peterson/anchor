# anchor

Consistency across the code-change lifecycle: issue, change request, review, release.

End-user docs: https://chris-peterson.github.io/anchor

This README is for working *on* anchor. What each skill does, how to configure
it, and which review backends it supports live on the docs site.

## Repo layout

```text
plugin.yml                   canonical descriptor — manifest, marketplace entry, docs previews
.claude-plugin/plugin.json   generated from plugin.yml; never hand-edited
skills/commit/               /anchor:commit — stage, test, review the changeset, then commit and push
skills/prepare-review/       /anchor:prepare-review — open the CR on the pushed branch, rebase if behind, draft the description
skills/resolve-feedback/     /anchor:resolve-feedback — fetch CR feedback; fix / reply / resolve each thread to resolution
skills/merge/                /anchor:merge — check the merge gates (wait on the pipeline), merge the CR, delete the branch
skills/release/              /anchor:release — establish the release model, recommend a version, draft notes, publish
skills/pipeline/             /anchor:pipeline — report a commit's forge pipeline state, or watch until it settles
skills/issue/                /anchor:issue — gather the why/consumer/acceptance; file a new forge issue (or update a known one)
skills/issues/               /anchor:issues — list and rank the issues assigned to you; recommend the next to work on
rules/                       ambient rules a SessionStart hook injects into every session
hooks/emit-rules.sh          the injecting hook (registered in hooks/hooks.json)
scripts/                     the helpers the skills shell out to — diff review, pipeline status, release recon, pre-flight state reads
guides/                      reference the skills and rules read at runtime
templates/                   the output shapes the skills produce, read at runtime
docs/                        end-user docs site (docsify, GitHub Pages); skills/, rules/, guides/, templates/ are rendered in
```

## Try the plugin locally

```bash
claude --plugin-dir .
```

Launches Claude Code with the working tree mounted as a plugin, so
`/anchor:commit` and `/anchor:prepare-review` resolve.

## Docs

```bash
just docs
```

Runs `shipyard build-docs` (renders each `SKILL.md`, rule, guide, and template
into `docs/`) and serves the docsify site locally. Deployed to GitHub Pages on
push to `main` via `.github/workflows/deploy-docs.yml`.

## License

MIT
