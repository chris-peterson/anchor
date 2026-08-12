# The `anchor` CLI

`anchor`'s skills are one caller of its helpers, not the only one. The same
review a skill launches is worth having from a plain shell, from a hook, and from
another agent that has two files to compare and no interest in the rest of the
lifecycle. `scripts/anchor` is that entrypoint: one executable every caller
reaches, so nobody re-derives an invocation from the scripts.

Reach for it through the slash shim inside a Claude Code session, or put it on
PATH for everything else:

```text
/anchor:anchor diff old.md new.md
```

```bash
anchor diff old.md new.md
```

## Commands

| Command | What it does |
|---|---|
| `anchor diff <left> <right>` | Review any two files or directories in the tool named by [`anchor.reviewBackend`](/guides/configuring), and print the [review contract](/spec) as JSON |
| `anchor completions zsh` | Print the zsh completion script; `--install` writes it and wires it into `.zshrc` |
| `anchor install-cli` | Write the PATH wrapper and install the completion |
| `anchor --version` | The version of the plugin this build came from |
| `anchor help` | The usage text (also `--help`, `-h`) |

## `anchor diff`

Two paths, no git range. The review opens in whichever backend
`anchor.reviewBackend` names, carrying a header you control:

```bash
anchor diff current-description.md proposed-description.md \
  --title "CR description, revised" \
  --detail "reviewer=you" --detail "budget=5 min"
```

`--detail` adds a header row and repeats. Neither path has to be in a git repo,
and neither has to be a file — two directories compare as trees.

What comes back on stdout is the review contract: the verdict, every comment with
the file and line it was anchored to, and which dimensions the backend can and
cannot express.

```json
{"backend":"revdiff","verdict":"changes-requested","comments":[{"body":"this
sentence promises a guarantee the code doesn't make","target":"line","file":"prop
osed-description.md","startLine":14,"endLine":14,"side":"new"}],"capabilities":{"
producesVerdict":true,"perHunkReview":false}}
```

A verdict of anything but `approved` is not approval, and an absent verdict is
not approval either — the CLI fails loudly rather than printing an empty object,
because silence and a clean review are otherwise the same output.

## Streams and exit codes

Two rules, so a caller never has to guess which half of the output to read:

- **stdout is the payload and nothing else.** For `diff` that is one JSON object;
  for `completions zsh` it is the completion script. Progress, warnings, and
  errors all go to stderr, so `anchor diff a b > review.json` writes a file you
  can hand to `jq` without stripping anything first.
- **the exit code reports whether the command ran**, not what it found. `0` ran,
  `64` is a usage error, other non-zero means it could not produce a result. The
  review verdict is a field in the JSON, where a caller reading comments is
  already looking — putting it in the exit status too would give two answers that
  can disagree.

## Putting it on PATH

```bash
/anchor:anchor install-cli
```

That writes a wrapper to `~/.local/bin/anchor` and installs the zsh completion in
the same step, because a completion nobody installed is a completion nobody has.

The wrapper records the path the plugin lived at when you ran it. A plugin update
moves the plugin and leaves the wrapper pointing at the old build, so `install-cli`
wants re-running after one. You don't have to remember: a SessionStart hook
compares `anchor --version` against the installed plugin's manifest each session
and says so when they differ. The skills and the slash command resolve the plugin
root themselves and are never stale — the wrapper is the only thing that drifts.
