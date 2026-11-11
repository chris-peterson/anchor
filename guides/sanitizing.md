# Sanitizing a draft before its gate

A draft is written from whatever the session holds, and a session working one
repo routinely holds another's hostnames, home paths, and tokens. In the
terminal they're unremarkable; in a public CR description they're a disclosure
published under the user's name. So every drafting skill scans what it drafted
against where it publishes, and resolves each finding, **before** the approval
gate opens (SPEC SANITIZE). The gate then approves the text that publishes,
substitutions included.

`scripts/sanitize-check.sh` decides what is present, the same way on every run.
You decide what stands in each finding's place.

## Run the scan

Scan every file the artifact publishes from: the body, and the title when it
publishes too (write it to a temp file of its own). Run it after the draft is
final and before the review or the approval question:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sanitize-check.sh" --file <draft> [--file <title-file>] \
  [--repo <checkout>] [--dest-host <host>] [--staged --path <p>...]
```

The **destination** is what a finding is measured against: an internal hostname
is unremarkable in a commit to that internal forge and a disclosure on
github.com. With neither flag the destination is the cwd's `origin`. Pass
`--repo <checkout>` when the target is another local checkout, and
`--dest-host <host>` (the host of `TARGET_URL`) when it has none. `--staged`
scans the lines the index adds, and is `/anchor:commit`'s alone.

Act on the block:

| Line | Meaning |
| --- | --- |
| `FINDING <kind> <source>:<line>:<col> <span>` | one span to resolve; a `credential` span is printed masked, so find it at its line and column |
| `FINDINGS=<n>` | `0` with exit 0: the draft is clean, the gate opens as usual, and the scan goes unmentioned |
| `ALLOWED=<n>` | findings an `anchor.allow` term suppressed; nothing to do |

Exit 65 means no destination resolved: pass `--dest-host`. Exit 64, 66, or 70 is
a usage, read, or scan error: report it, and the gate doesn't open.

## Resolve each finding in the prose

Stand a placeholder in the finding's place that keeps its shape, so the reader
can substitute their own value into it (SANITIZE-07):

| Kind | Finding | Stands in its place |
| --- | --- | --- |
| `host` | a CI or forge host | `<internal-gitlab-host>`, `<ci-host>`; a URL keeps its scheme and path: `https://<ci-host>/job/<id>` |
| `path` | a path through a home directory | `<path-to-repo>/scripts/x.sh`, `~/<repo>` |
| `credential` | a token, `user:pass@`, a bearer value | `<token>`, `https://<user>:<token>@<host>/…`, `Bearer <token>` |
| `tracker` | a link readers can't follow | the ticket's id as plain text (`PROJ-12`), or `<ticket-url>` |
| `deny` | a term the user configured | ask, unless the sentence reads whole without it |

Prose naming what was removed ("an internal host") is not a placeholder: a
technical sentence then carries an English clause where a token belongs.

**Where no placeholder is clear, ask** (SANITIZE-08) with `AskUserQuestion`,
header `Sanitize`, one question per finding, each naming the finding, its line,
and the sentence it sits in:

- **Replace with…**: the user types the text (the free-text answer).
- **Keep it in this `<artifact>`**: the user allows it for this one publish.
- **Stop**: nothing publishes.

Offer no default text of your own there, and never suggest a config key holding
replacement text: none exists.

Re-run the scan on the revised draft until `FINDINGS=0`, or until every finding
left is one the user chose to keep.

### A finding in the staged diff

A finding in code is not yours to rewrite: a hostname in a test fixture or a
path in a config file may be what the change is for. Ask about each one, with the
same question, where **Replace with…** means the user edits the file (re-stage
it and re-run the tests before the gate) and **Keep it** keeps it in this commit.

## Show the substitutions at the gate

The gate approves the substitutions with the prose (SANITIZE-09). Under the
review manifest, or above the approval question where the skill asks in chat,
list each one:

| Found | Where | Now |
| --- | --- | --- |
| `host` `git.acme.example` | Validation, line 3 | `<internal-gitlab-host>` |
| `credential` `glpat-***` | line 9 | `<token>` |
| `path` `/Users/<name>/src/widget` | `scripts/x.sh:12` | kept, as you chose |

Print a credential masked, as the scan does. With nothing found, the table is
left out.

## An unresolved finding publishes nothing

A finding neither replaced nor kept stops the artifact (SANITIZE-10): the gate
doesn't open and nothing is written, as with an artifact the user hasn't
approved. Say which findings remain.

## When the same finding comes back

A finding the user keeps on every run of a repo, such as a public host the
scan doesn't know or a project's own codename, is the case for an allow term.
Name the command for the user to run; don't set it yourself:

```bash
git config --add anchor.allow <term>            # every destination
git config --add anchor.github.allow <term>     # only what publishes to GitHub
```

The keys, and `anchor.deny` for terms that must never publish, are in the
[configuring guide](configuring.md#key-deny-allow).
