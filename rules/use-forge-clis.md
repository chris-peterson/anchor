# Drive forge operations through `gh` / `glab`

When the user shares a forge URL or asks about a change request, issue, or
repository, use the forge's dedicated CLI — `gh` for GitHub, `glab` for
GitLab. Pick by the `origin` remote. Both CLIs reason reliably from explicit
flags, and anchor's skills standardize on them.

**Opening a CR is the exception — route it through `/anchor:create-review-request`,
never a bare `gh pr create` / `glab mr create`, even when the CR is only a
sub-step of a larger task (a rollback, a follow-up fix).** A raw `create`
lands the CR non-draft, with no source-branch cleanup, the project template's
checklist left intact, and no Review guide; `create-review-request` sets the draft
flag and `--remove-source-branch`, composes the project template, and drafts
the canonical Review guide. The moment work needs a PR/MR, hand off to
`create-review-request` rather than improvising the `create` inline. Editing or
querying an *existing* CR still uses the CLI directly, per below.

For any multi-line body (tables, code fences) — CR descriptions, issue
bodies, comments — write the body to a unique temp file
(`$(mktemp -u "${TMPDIR:-/tmp}/cr-body.XXXXXX").md`) and pass it by file (`--body-file`,
`-F description=@<path>`); never inline escape-quoted strings.

For anything beyond these basics — creation defaults, line-anchored
discussions, the known CLI gaps and their workarounds — read the bundled
forge cookbook before re-deriving an invocation:
`${CLAUDE_PLUGIN_ROOT}/guides/forge-cookbook.md`
