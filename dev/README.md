# Local plugin pinning

Use the checkout as the active Anchor plugin in both Claude Code and Codex:

```bash
./dev/pin-local.sh
```

Restore the latest released Anchor from the canonical `chris-peterson`
marketplace:

```bash
./dev/unpin-local.sh
```

Claude Code loads the checkout in place through `~/.claude/skills/anchor`, so
new sessions see subsequent edits directly. Codex installs local marketplace
plugins into its cache; rerun `pin-local.sh` after an edit to refresh its
snapshot. Start a new host session after either script. The first Codex session
may also ask you to review and trust Anchor's bundled hook through `/hooks`.

Both scripts default to user-level host configuration. Their paths and canonical
marketplace can be redirected for testing or an alternate installation:

- `CLAUDE_CONFIG_DIR` or `ANCHOR_CLAUDE_SKILLS_DIR`
- `CODEX_HOME` or `ANCHOR_CODEX_LOCAL_MARKETPLACE_DIR`
- `ANCHOR_OFFICIAL_MARKETPLACE` and `ANCHOR_OFFICIAL_MARKETPLACE_SOURCE`
- `ANCHOR_LOCAL_MARKETPLACE`

Each host is optional. If only `claude` or only `codex` is on `PATH`, the scripts
configure that host and do not create, inspect, or remove directories belonging
to the absent host. With neither installed they report that there is nothing to
do and exit successfully.
