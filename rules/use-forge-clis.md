# Drive forge operations through `gh` / `glab`

When the user shares a forge URL or asks about a change request, issue, or
repository, use the forge's dedicated CLI — `gh` for GitHub, `glab` for
GitLab. Pick by the `origin` remote. Both CLIs reason reliably from explicit
flags, and anchor's skills standardize on them.

**The line is authoring vs. mechanical.** *Authoring* a forge artifact —
composing the WHY-first prose a reader leads with — goes through the anchor
skill that shapes it. `gh` / `glab` is for the *mechanical* and *query* half:
viewing, listing, labeling, assigning, closing, status checks. The CLIs are the
tool for the mechanical half, never a substitute for the skill on the authoring
half — even when the artifact is only a sub-step of a larger task (a rollback, a
follow-up fix).

- **Writing or revising a CR description → `/anchor:prepare-review`**, never a
  bare `gh pr create` / `glab mr create` or a `--body` on an edit. A raw
  `create` lands the CR non-draft, with no source-branch cleanup, the project
  template's checklist left intact, and no Review guide; `prepare-review` sets the
  draft flag and `--remove-source-branch`, composes the project template, and
  drafts the canonical Review guide.
- **Filing or updating an issue → `/anchor:issue`**, never a bare
  `gh issue create --body` / `glab issue create --description`. The skill leads
  the issue with *why* the work is needed, written for a reader who's never seen
  that part of the system — the shape a raw `create` drops.

The moment work needs a PR/MR or an issue *body*, hand off to the skill rather
than improvising the `create` inline. Editing or querying an *existing* CR or
issue — labels, assignees, state, comments, views — still uses the CLI directly.

For any multi-line body the skill produces (tables, code fences) — CR
descriptions, issue bodies, comments — write it to a unique temp file
(`$(mktemp -u "${TMPDIR:-/tmp}/cr-body.XXXXXX").md`) and pass it by file (`--body-file`,
`-F description=@<path>`); never inline escape-quoted strings. (That's the skill
writing the body it composed — the mechanical half — not a consumer
hand-authoring one.)

For anything beyond these basics — creation defaults, line-anchored
discussions, the known CLI gaps and their workarounds — read the bundled
forge cookbook before re-deriving an invocation:
`${CLAUDE_PLUGIN_ROOT}/guides/forge-cookbook.md`
