# Ambient rules

Most of anchor's guidance loads only when a skill runs. A few of its
invariants can't wait for that — they guard actions an agent might take when
no skill is involved, like amending a commit ad-hoc or re-deriving a forge
call from scratch. The plugin injects these as **ambient rules**: a
`SessionStart` hook adds `rules/*.md` to the session context at startup and
re-injects them after context compaction.

This page shows exactly what gets injected, so you can see what installing
anchor adds to your sessions.

A rule only asks. Where an agent ignoring one would publish something under your
name, a `PreToolUse` hook also blocks the command and names the skill to use
instead. So far that covers publishing a release: a direct `gh release create`,
`glab release create`, or release-workflow dispatch is blocked and redirected to
`/anchor:release`, which runs the same publish after you confirm it.

---

[rewrite-history-through-anchor](rules/rewrite-history-through-anchor.md ':include')

---

[use-forge-clis](rules/use-forge-clis.md ':include')

---

[omit-attribution-trailers](rules/omit-attribution-trailers.md ':include')
