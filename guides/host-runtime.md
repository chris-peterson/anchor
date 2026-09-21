# Host runtime

Anchor runs under more than one agent host. Skill prose names capabilities and
bundled paths without assuming a particular host's tool names or environment.

## Resolve `<anchor-root>` once

`<anchor-root>` means the absolute path to the installed Anchor plugin root.
Resolve it before reading a bundled file or invoking a helper, then replace the
token with that absolute path in every command. Do not pass the token literally
to the shell.

Use the first source the host makes available:

1. The installed plugin root supplied by the host. Claude Code exposes it as
   `CLAUDE_PLUGIN_ROOT`.
2. The absolute path of the loaded skill's `SKILL.md`; `skills/<name>/SKILL.md`
   is two directories below the plugin root. Codex includes that path when it
   presents an installed skill.
3. The `Anchor plugin root:` line emitted by Anchor's `SessionStart` hook.

The hook process cannot export an environment variable into later shell calls.
Resolve the path in the skill and use the absolute path directly rather than
assuming a variable from an earlier command still exists.

## Ask, read, write, and wait through the host

Before following a skill's phases, read
`<anchor-root>/guides/reading-instructions.md`. It governs complete phase reads
and targeted, bounded reads of the larger shared guides. A reference's location
does not change the installed root: derive it from the entry point's
`skills/<name>/SKILL.md`, not from a file inside `references/`.

Where a skill says to ask with structured choices, use the host's structured
question mechanism when one is available; otherwise ask the question directly
with the same options and recommendation.

Where a skill starts a blocking helper in the background, use the host's
long-running-command or session mechanism, retain its handle, then wait for or
poll that handle and read its captured stdout. The capability matters; names
such as Claude Code's `BashOutput` and Codex's session polling do not belong in
the workflow itself.

Use the host's ordinary file-reading and file-writing mechanisms for local
artifacts. Preserve every approval and presentation gate regardless of which
mechanism supplies the capability.

## Name skills without choosing a host syntax

Within Anchor, `anchor:commit` means the bundled `commit` skill, and likewise
for the other skill names. Claude Code invokes it as `/anchor:commit`; Codex
invokes it as `$anchor:commit` or through `/skills`. A handoff to another Anchor
skill means load and follow that skill, not type one host's invocation syntax
into another host.
