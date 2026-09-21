## Step 1: Stage and read changes

**This is the first command the flow runs.** It's cheap, deterministic, and it decides whether the later steps have anything to do — so nothing precedes it, tests included. Run the pre-flight recon **once**; it stages the paths you name, then gathers the resolved checkout, staging state, stat, branch/default, ahead-count, squash gate, and `anchor.*` config into one `KEY=value` block, so the steps below read a single command's output instead of six separate probes:

```bash
bash "<anchor-root>/scripts/commit-preflight.sh" --path <p> [--path <p>...]
```

**Name every path you changed, and nothing else.** One `--path` per file, relative to `REPO_ROOT`; an absolute path is refused. This is not `git add -A`: a checkout can be shared with another agent session, and staging the whole tree puts that session's in-flight files into your review and your commit, under a message that doesn't describe them. Take the list from the edits *you* made this session — the files you wrote, plus any you deleted or renamed. A path with nothing to stage is an error (exit 65), which is how a typo or a wrong-root path surfaces instead of quietly dropping a file from the commit.

If the user asks to commit work you didn't make yourself, list the paths from `git status --porcelain` first, show them, and confirm the set before staging.

Act only on the keys; don't re-run the folded-in probes (`git add`, `look-ahead.sh`, `squash-check.sh`):

| Key | Use |
|-----|-----|
| `REPO_ROOT` | the resolved checkout — the target this run operates on (see "Target repo") |
| `STAGED` | `1` → a change to commit (read its full diff below, then test in Step 2); `0` → see push-existing |
| `OTHER_STAGED` | `>0` → someone else staged paths you didn't name. Say so, name the count, and carry the same `--path` list into Steps 5-6 so their work stays out of your commit. Don't unstage it — it isn't yours |
| `STAT` | the diffstat total — what's in scope |
| `BRANCH` / `DEFAULT_BRANCH` / `ON_DEFAULT_BRANCH` | the branch decision in Step 4 |
| `AHEAD` | unpushed commit count (empty = no upstream) — drives push-existing |
| `SQUASH` / `SQUASH_FORCE_PUSH` / `ALLOW_MESSAGE_AMEND` / `PRIOR_SUBJECT` | the squash gate in Step 4 |
| `ANCHOR_CONFIG` | the `anchor.*` keys (JSON) for Steps 3-4 |

When `STAGED=1`, read the full staged diff so you can draft the message:

```bash
git diff --cached
```

**Push-existing** — when `STAGED=0`: if `AHEAD` is `0` or empty, nothing is staged and nothing is unpushed — warn there are no local changes and stop. If `AHEAD` is `≥1`, the branch has unpushed commit(s) to push: **skip Steps 2-4**, review that range in Step 5 (`review-diff.sh --commit`, not `--local`), and push in Step 6. Read the range (substitute `DEFAULT_BRANCH`):

```bash
git diff "origin/main...HEAD"
```

(The message-only-amend case — an unpushed commit whose *message* is wrong, tree unchanged — is the `ALLOW_MESSAGE_AMEND` path in Step 4, not this push-only path.)

## Step 2: Run tests

Reached only when Step 1 found something to commit (`STAGED=1`). **Skip the suite on the push-existing and nothing-to-do routes** — there's no new code to test, and those commits were tested when they were made. Running it there spends the wall-clock of a full suite to learn the run is a `git push`.

Look for a test runner in the project (e.g., `just test`, `npm test`, `dotnet test`, `pytest`, `go test ./...`, a `Makefile` test target) and run it. Discovery is yours on purpose rather than scripted: you can report progress on a slow suite, pick the right target when a repo exposes several, and act on a failure in the same pass.

**Gate on the exit code, not on the output.** A suite's stdout is not a reliable pass/fail signal: a runner that exercises a validator against known-bad fixtures prints `*** Found 1 error(s)` on a *successful* run, and `| tail -30` of that reads as a failure. Reading the output then re-running to get a clean exit code runs the suite twice. So capture the status on the first invocation and let that decide. Run the suite bare and read the status the harness reports with it; a non-zero exit is surfaced without you asking for it. Where you need a pipeline's status, put the pipeline in a script and run the script — the safety analyzer reads only the outer command line, so `${PIPESTATUS[0]}` inside `bash run-tests.sh` costs nothing, while a `;`-sequenced `echo "exit: $?"` on the command line is gated on its shape and no allow rule can reach it.

**Run the suite as its own Bash call.** Don't chain it onto another command with `&&` or fold it into a `$(…)`: a compound hides the consequential step from the permission prompt, and a non-zero exit from either half becomes ambiguous.

**A passing suite is silent.** Don't report it: it's an input to the next step, not a decision the user makes (`<anchor-root>/guides/execute-quietly.md`). Proceed to Step 3 without a word about tests.

If tests fail, **stop and fix them**. Present the failures and help the user resolve them. Do NOT proceed to Step 3 until the test suite exits cleanly. No exceptions — "pre-existing" failures still block the commit.

If no test suite is found, skip this step silently.
