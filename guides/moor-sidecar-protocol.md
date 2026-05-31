# moor Context Protocol

[moor](https://github.com/chris-peterson/moor) is a fast, keyboard-driven diff
viewer for reviewing changes. anchor's `commit` and `preview` skills launch it
for the visual-review step. Anything that launches moor needs two things from
it: a way to **hand moor context about what's being reviewed** (so the user sees
the commit subject / body / metadata in moor's header), and a way to **recover
the review outcome** — accepted, rejected hunks with reasons, unreviewed, or
closed early. `git difftool --dir-diff` swallows the process exit code, so moor
uses a JSON sidecar file as a bidirectional channel: the caller writes the
`input` section before launch; moor writes the `output` section continuously
during the review.

moor is an **optional** integration. When `moor` isn't on PATH (or the launch
helper is missing), the skills skip the visual-review step and say so in one
line — the commit/preview still completes. The rest of this guide describes the
contract when moor *is* installed.

## Launch

Launch the difftool via the bundled helper (never raw `git difftool`, which sets
no context and discards the verdict):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/moor-review.sh" <diff-range>
```

The script:

1. Generates a unique cache path: `~/.cache/moor/context-<PID>.json`.
2. Pre-populates the file's `input.title` and `input.details` with commit metadata derived from the diff range (commit subject, body, author, short hash for a HEAD-relative range; working-tree summary for `HEAD`).
3. Exports `MOOR_CONTEXT=<that path>`.
4. Runs `git difftool --no-prompt --dir-diff "<diff-range>"`.
5. Echoes `MOOR_CONTEXT=<path>` so the caller can locate the result file.

Common diff ranges:

| Caller | Range | Compares |
|---|---|---|
| `commit` (first unpushed) | `@{upstream}...HEAD` | Full delta since origin |
| `commit` (2+ unpushed) | `HEAD~1...HEAD` | Just the new commit |
| `preview` | `HEAD` | Working tree vs HEAD |

## Reading the context file

Parse the echoed `MOOR_CONTEXT` line from the command output, then use the
**Read tool** (not bash, not glob) to read the file directly. If the file is
missing or the `output` section is absent, treat it the same as `exitCode` 3.

The file's shape:

```json
{
  "input": {
    "title": "Reframe MOOR_CONTEXT as bidirectional input/output",
    "details": [
      { "label": "commit", "value": "7c4a2e1" },
      { "label": "author", "value": "Ada Lovelace <ada@example.com>" },
      { "label": "body",   "value": "Long-form context that wraps onto multiple lines and is shown only when the user expands details." }
    ]
  },
  "output": {
    "exitCode": 1,
    "reviewer": "Ada Lovelace",
    "rejections": [
      { "file": "/path/to/file.js", "hunk": 0, "line": 42, "reason": "this method should be private" }
    ]
  }
}
```

The `input` section is what the caller wrote; the `output` section is what moor
wrote. Read `output` for the review verdict.

**A note on `exitCode`:** moor writes `rejections` continuously during the review
(so a watching caller sees live feedback), but `exitCode` lands only after moor
exits. Its presence signals that the review has been finalized; its absence
signals an in-progress review whose rejections may still change. Skills reading
the file after `git difftool` returns will always see `exitCode` populated.

## Exit-code interpretation

The exit code drives the caller's next action. Skills phrase the output line to
match their domain (`Committed [sha]` vs `Previewed`), but the underlying state
and follow-up are identical:

| `exitCode` | State | Caller follow-up |
|---|---|---|
| `0` | All hunks accepted | Output the success line. No other summary. |
| `1` | Rejected hunks with reasons | Output the rejection line. List each rejection with file/line/reason. **Act on the feedback**: read the named files, fix the issues, loop back to the skill's first step. Do not ask the user to re-explain — the rejection reasons are the instructions. |
| `2` | Unreviewed hunks (some not touched) | Output the unreviewed line and ask the user what to change. |
| `3` or unknown | Closed without reviewing (e.g. exited before hunk counting finished) | Output the closed-without-review line and ask the user what to change. |

## Don't delete the context file

Letting the result files accumulate avoids a Claude Code permission prompt for
`rm`-like cleanup. They are tiny (a few KB), live under `~/.cache/moor/`, and
naturally recycle as PIDs are reused.
