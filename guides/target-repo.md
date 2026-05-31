# Target-repo resolution

Skills that run git operations (`commit`, `preview`, `prepare-review`) resolve
**which** repo they target before running anything. The working directory at
invocation time is not a reliable proxy: the user may be in a parent shell while
edits landed in a sibling repo, a prior invocation's target may have drifted out
of scope, or an absolute-path edit may have written outside the current tree.
Each invocation re-resolves so prior targets never carry forward implicitly.

## With an argument (`/<skill> <name>`)

1. **Build the candidate set** — every git repo the session has touched. Walk
   recent file edits in the conversation, run
   `git -C <path> rev-parse --show-toplevel` for each, deduplicate.
2. **Match** `<name>` as a case-insensitive substring against each candidate's
   basename (last path component of the toplevel).
3. **Exactly one match** — use it. Confirm in one line:
   `Targeting **<basename>** (<full-path>)`. Proceed.
4. **No matches** — say `No project matching "<arg>". Touched projects: <list>.
   Which one?` and wait.
5. **Multiple matches** — say `Multiple projects match "<arg>": <list>. Which
   one?` and wait.

## Without an argument

Resolve from the working directory:

```bash
git rev-parse --show-toplevel
```

State the resolved path. Then ask which repo to target if any of these apply:
the session touched files in more than one git repo; files were edited via
absolute paths outside the working directory's repo; the user names a repo that
differs from the working directory; or the working directory is not inside any
git repo.

## After resolution

All git commands operate on the target repo. If the working directory doesn't
match, run git with `-C <repo-path>` rather than `cd` — staying put avoids
surprising the user when the skill finishes and they continue in the parent
shell.
