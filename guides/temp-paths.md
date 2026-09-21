# Temp paths a caller can grant

Every skill that composes a forge artifact writes it to a temp file and passes it
by file. The path in that instruction is part of the instruction: a caller grants
paths by prefix, so a prescribed path that resolves outside their grant costs
them a permission prompt on every run, for as long as the guidance stands.

## The prescribed form

```bash
$(mktemp -u /tmp/cr-body.XXXXXX).md
# → /tmp/cr-body.aB3xKp.md
```

A literal `/tmp`, `-u` so the name comes back uncreated, `XXXXXX` **trailing**
with the suffix appended outside the template, and a fresh name per call so two
sessions writing the same kind of artifact can't clobber each other.

Keeping `XXXXXX` trailing is not style. BSD/macOS `mktemp` replaces only a
trailing run, so it takes `cr-body.XXXXXX.md` as a literal filename — creating
that file verbatim, then failing on it the next run with `mkstemp failed … File
exists`. `$(mktemp -u …XXXXXX).md` behaves identically on GNU, BSD, and Git
Bash's mktemp.

## Pair the path with the host rule that covers it

The path and the allow rule are one decision. Writing down only the path is what
lets them drift apart.

Claude Code expresses that grant in `settings.json`:

```jsonc
// The literal prefix, plus the path it resolves to on your platform; see the
// resolution table below for what that is.
"permissions": { "allow": ["Edit(//tmp/**)", "Edit(//private/tmp/**)"] }
```

Codex expresses the same boundary through its permission profile and writable
roots. The syntax differs; the requirement is the same: allow the literal
`/tmp` path and, where the host resolves symlinks first, its real platform path.

## Why not `${TMPDIR:-/tmp}`

It reads as the more careful, more portable form, which is what makes it a trap:
the *fallback* is what a caller can grant and the *primary* is what prompts.

| Platform | `$TMPDIR` | `${TMPDIR:-/tmp}` resolves to | a `/tmp` grant matches |
| --- | --- | --- | --- |
| macOS | always set, `/var/folders/<hash>/T/` | `/var/folders/…` | no |
| Linux | usually unset | `/tmp` | yes |
| Windows, Git Bash | unset | `/tmp` | yes |

So the same line is silent on Linux and prompts on every body write on macOS.

**Two of the three resolve `/tmp` somewhere else, so grant the real path too.**
A literal `/tmp` is what the *written* path matches; whether that is enough
depends on whether a permission check resolves the path before matching, and only
Linux has nothing to resolve:

| Platform | a literal `/tmp/x` really lives at | so also grant |
| --- | --- | --- |
| Linux | `/tmp/x` | nothing further |
| macOS | `/private/tmp/x` — `/tmp` is a symlink to `private/tmp` | also grant `/private/tmp` |
| Windows, Git Bash | `<user temp>/x` — `/tmp` is a mount over the user's own temp dir, `/c/Users/<name>/AppData/Local/Temp` on the CI runner | the caller's own temp path; there is no shared prefix |

Granting only the literal prefix leaves the prompt in place whenever the check
resolves first.

## Shells and platforms this assumes

anchor's prescribed commands assume a **POSIX shell** — bash or zsh on macOS and
Linux, and Git Bash on Windows. Every script under `scripts/` is
`#!/usr/bin/env bash`, and the prescribed one-liners use `mktemp` and `$(…)`.

Claude Code can run shell commands through Git Bash. Codex uses native
PowerShell on Windows and a Linux shell in WSL2. Anchor currently supports
Windows through **Git Bash or WSL2**; a native PowerShell-only session has no
`mktemp`, cannot run Anchor's Bash helpers as prescribed, and is not a supported
runtime yet. The equivalent temporary-path expression there is:

```powershell
$p = Join-Path $env:TEMP ("cr-body-{0}.md" -f [guid]::NewGuid().ToString("N").Substring(0,6))
```

`$env:TEMP` is per-user (`C:\Users\<name>\AppData\Local\Temp`), so there is no
single literal prefix that covers every caller — the allow rule has to name the
user's own temp directory. That is the *same* directory Git Bash's `/tmp` is
mounted over, so the two Windows shells differ in the written path rather than in
where the file lands: Git Bash gets a grantable literal `/tmp` in front of it,
and PowerShell does not. `New-TemporaryFile` is the built-in alternative, but it
*creates* the file, so a follow-up write is an overwrite rather than a fresh
name.

> [!NOTE]
> Nothing in anchor's CI exercises a native PowerShell-only install; the
> `windows-latest` matrix job runs under Git Bash. Codex users on Windows should
> use WSL2 or Git Bash until Anchor carries a native PowerShell implementation.
> Treat the exact allow-rule pattern for `$env:TEMP` as unverified until one is
> added and tested.

## anchor's own scripts honor `$TMPDIR`, deliberately

`scripts/lib/tmpfile.sh` uses `${TMPDIR:-/tmp}` and is right to. The two answer
to different readers: the safety analyzer reads the outer command line it is
handed, so a `mktemp` inside `bash scripts/foo.sh` is invisible to it. A script
is therefore free to respect a per-user temp dir, while prescribed text — which
the analyzer does read — is not.

**Prescribed text: a literal `/tmp`. Script internals: `$TMPDIR`.**

`tests/tmp-path-guidance.test.sh` holds both halves in place, and runs on the
ubuntu / macOS / Windows matrix because the claims above are per-platform.

## Shapes that no allow rule can reach

A path-scoped rule matches a prefix; a **compound shape is gated on the shape
alone** and cannot be approved by any permission entry. So a prescribed command
must not chain (`;`, `&&`, `||`) or substitute (`$(…)`, backticks) around the
consequential step.

The `$(mktemp -u …)` above is the one substitution that stays, because it is the
*value* being computed rather than a guarded operation being hidden — and a
caller who grants the write does not need the name computed separately. Where a
prescribed step is consequential (a commit, a push, an install, a test suite),
run it bare and read what it printed.

Where you genuinely need a pipeline's exit status, put the pipeline in a script
and run the script: the analyzer only reads the outer command line, so
`${PIPESTATUS[0]}` inside `bash run-tests.sh` costs nothing, where
`<runner>; echo "exit: $?"` on the command line is refused on its shape.
