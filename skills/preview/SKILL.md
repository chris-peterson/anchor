---
name: preview
description: Stage all local changes and open them in the visual difftool for review. Triggers on 'preview', 'diff', 'review my changes', 'show changes'.
---

# Preview Local Changes

Stage all local changes (staged + unstaged) and launch [moor](https://github.com/chris-peterson/moor) against `HEAD` so the user can review the in-flight work before committing. Reuses the same moor sidecar protocol as `/commit` so directed feedback (rejected hunks with reasons) flows back as actionable edits.

```mermaid
%%{ init: { 'look': 'handDrawn' } }%%
flowchart TD
    Start(["/preview"]) --> Repo["Confirm target repo"] --> Stage

    subgraph "Step 1: Stage"
        Stage["git add -A"] --> Staged{Changes vs HEAD?}
        Staged -->|No| Stop([No local changes])
        Staged -->|Yes| DiffTool
    end

    subgraph "Step 2: Visual Diff"
        DiffTool["Launch difftool against HEAD"] --> Review{Review result?}
        Review -->|Accepted| Done([Done])
        Review -->|Rejected| Fix["Fix rejection reasons"] --> Stage
        Review -->|Unreviewed / Closed| Ask([Ask user what to change])
    end
```

/preview is a two-step skill (stage, diff), so it does not allocate its own tasks. If invoked inside an orchestrator (a task is already `in_progress` when you call `TaskList`), just run the steps below; the orchestrator's task list stays intact.

## Target repo

Before anything else, resolve which repo this operates on — the working directory isn't a reliable proxy (edits may have landed in a sibling repo). Re-resolve on every invocation; don't assume the previous target carries forward.

- **With an argument** (`/anchor:preview <name>`): case-insensitive substring-match `<name>` against the basename of every git repo the session has touched. One match → use it (confirm in one line). Zero or multiple → list the candidates and ask.
- **No argument**: run `git rev-parse --show-toplevel` from the working directory. If the session touched more than one repo, or edits landed outside it, state the resolved path and ask which to target.

Run git with `-C <repo>` when the working directory isn't the target, rather than `cd`.

## Step 1: Stage all changes

Stage everything so the index equals the working tree. Staging up front keeps the difftool invocation simple (one range against `HEAD`) and surfaces any further edits made in response to rejection feedback as fresh unstaged hunks on the next pass.

```bash
git add -A
```

Then check whether there's anything to preview:

```bash
git diff --cached --stat HEAD
```

If the output is empty, tell the user there are no local changes to preview and stop. Mark the remaining task `deleted`.

Otherwise, display the `--stat` summary so the user can see what's about to open in the difftool, then proceed.

## Step 2: Launch visual diff

Compare the working tree (now identical to the index after `git add -A`) against `HEAD`. This is the full surface of local changes — staged and previously-unstaged together.

moor is **optional** — check it's installed first:

```bash
command -v moor
```

**If `moor` isn't on PATH**, delegate to git's configured difftool in directory mode. There's no `MOOR_CONTEXT` sidecar this way, so the rejected-hunk feedback loop isn't available — stand in for it by asking the user after the difftool closes:

```bash
git difftool --no-prompt --dir-diff HEAD
```

Then ask `Anything to change, or run /commit? [describe changes / commit]`. If the user names changes, apply them, re-stage, and re-open the difftool. Otherwise report `Previewed via git difftool — moor not installed; staged changes are ready, run /commit when you're set`.

**If moor is present**, launch the wrapper (passing `HEAD` as the diff range). `git difftool` inside the wrapper blocks until you close moor, so run it as a **background** Bash call (`run_in_background: true`) — a foreground call holds the turn open until the Bash timeout. Read the wrapper's stdout with the **BashOutput tool**, not `tail` / `$(...)` on the task output file (which trips the command-substitution permission gate). Poll until the `MOOR_CONTEXT=<path>` line appears — the wrapper echoes it once moor closes — then use the **Read tool** on that path for `output.exitCode` / `output.rejections`. moor's sidecar contract is defined in its [`SPEC.md`](https://github.com/chris-peterson/moor/blob/main/SPEC.md) (`IM.OUT-*`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/moor-review.sh" HEAD
```

/preview-specific phrasing:

- **`output.exitCode` `0`** → `Previewed — no rejections`. No other summary text.
- **`output.exitCode` `1`** → `Previewed — rejected hunks detected`, list `output.rejections`, then loop back to Step 1 (re-stage and re-preview after the fix).
- **`output.exitCode` `2`** → `Previewed — unreviewed hunks, what do you want to change?`
- **`output.exitCode` `3` or absent** → `Previewed — difftool closed without review, what do you want to change?`
