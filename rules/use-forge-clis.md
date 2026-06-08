# Drive forge operations through `gh` / `glab`

When the user shares a forge URL or asks about a change request, issue, or
repository, use the forge's dedicated CLI — `gh` for GitHub, `glab` for
GitLab. Pick by the `origin` remote. Both CLIs reason reliably from explicit
flags, and anchor's skills standardize on them.

For any multi-line body (tables, code fences) — CR descriptions, issue
bodies, comments — write the body to a unique temp file
(`mktemp -u /tmp/cr-body.XXXXXX.md`) and pass it by file (`--body-file`,
`-F description=@<path>`); never inline escape-quoted strings.

For anything beyond these basics — creation defaults, line-anchored
discussions, the known CLI gaps and their workarounds — read the bundled
forge cookbook before re-deriving an invocation:
`${CLAUDE_PLUGIN_ROOT}/guides/forge-cookbook.md`
