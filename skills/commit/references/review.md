## Step 5: Review the pending changeset

Before committing, open the pending changeset — the working tree vs `HEAD`, the exact changes Step 6 will commit — in a visual review, **with the drafted message shown alongside it**. Launch the **dispatcher** in `--local` mode with `--message-file` (the message file from Step 3) — **not** raw `git difftool`. It stages the paths you name so a new file is in the diff at all, diffs the tree against `HEAD`, seeds the drafted message (subject as the headline, body as prose) plus a repo/branch/summary header, runs the mode the subject calls for — a git range names a base to compare against, so that is `diff`, run by `anchor.diff.tool` (`revdiff` by default); see the configuring guide's Defaults table, and — once it closes — prints the normalized result on its own stdout. So you review the message and the diff *together*, with no separate chat gate. Raw `git difftool` bypasses the header and the verdict.

**Launch with the host's background/session mechanism and retain its handle**:
the dispatcher blocks until the review closes, so a foreground call would hold
the turn open until the command timeout.

**Print the manifest as you launch.** The tool draws one file at a time and never shows the set, so the message that launches the review carries a table of the files under review with their `+`/`−` counts (Step 1's `STAT` covers the same paths), the repo and branch, the tool, and the drafted commit message riding with them. The shape is in `<anchor-root>/guides/execute-quietly.md` under "show what is going under review". Nothing else about the launch is output — not the command, not the flags, not the wait. After the table, the next thing you say is the verdict (or what the review asked for).

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill commit --local --message-file <commit-msg-path> --path <p> [--path <p>...]
```

`--skill commit` tells the adapter which artifact is under review; it doesn't pick the mode, which follows the subject. Pass it on every launch below.

Pass the **same `--path` list** you gave the Step 1 pre-flight. The review and the commit have to cover the same set of files, or the user grades a changeset that isn't the one that lands.

(On the **push-existing** path from Step 1 — nothing staged, unpushed commits to push — there's no drafted message; review those commits instead of the working tree: `review-diff.sh --skill commit --commit`. That path is a diff with no drafted artifact, so on `edit` mode it returns `no-verdict` naming the key to change — report that rather than pushing unreviewed.)

When the background command completes, read its captured stdout through the
host's command-session mechanism — not `tail` / `$(...)`, which trip the
command-substitution gate. The last lines carry the verdict (no separate file
read):

- `REVIEW_VERDICT` — `approved` · `changes-requested` · `incomplete` · `no-verdict`.
- `REVIEW_OUTPUT` — compact JSON carrying `verdict`, `mode`, `tool`, `comments[]`, `editedFields[]`, `capabilities`, and `raw` (the DIFF contract, defined normatively in the plugin `SPEC.md`). Each comment is `{body, target, file?, startLine?, endLine?, side?}`, where `target` is `line` / `file` / `changeset`. Comments are ungraded: every one is feedback to address, and the verdict — not a per-comment tier — says whether it blocks.

Act on the verdict:

- **`approved`** → the changeset is clean; proceed to Step 6 to commit and push. If `comments` is non-empty, the reviewer approved *and* left feedback: surface it — the verdict says it doesn't gate the commit, but the user may want to act on it (now, or as a follow-up). A comment that asks for the follow-up itself (*file an issue for this*) is an instruction rather than a remark: carry it out, through `anchor:issue` where it asks for an issue.
- **`changes-requested`** → **do not commit.** List every comment — they're ungraded, so all of them are the ask — then loop back to Step 2. **A comment whose `target` is `file` and whose body carries a diff is the reviewer's own edit**, not an annotation: they wrote into the changeset through a difftool. Read it per `<anchor-root>/guides/reviewer-edits.md` — keep the fixes, answer the questions, and take their comment lines back out before committing. Otherwise: fix the commented lines in the working tree, re-run tests, and re-review. **If a comment's `body` is short** (e.g. "I don't get what this flag means") **and the cited line range contains more than one distinct change** (e.g. two flag additions in a usage block, two unrelated lines in the same range), ask the user which token the comment refers to before fixing — a one-second clarification beats several minutes of guessing wrong. Fix the commented lines themselves; don't expand into adjacent pre-existing code (`<anchor-root>/guides/changeset-scope.md`).
- **`incomplete`** → `Unreviewed changes — what do you want to change?` Nothing is committed until the review is clean.
- **`no-verdict`** → nothing is committed; read the cause from the result, say what happened in one line, and walk the fallback ladder in `<anchor-root>/guides/review-fallback.md`. `capabilities.producesVerdict: false` means the tool graded nothing, so the ladder applies to it exactly as it does to a tool that died (see `raw.exitCode`). **Never ask `Reviewed in your diff viewer — commit and push?`**: a launched window is not evidence anything was read, and treating it as approval is what the verdict exists to prevent. Here the ladder's changeset rung is the one to walk — go file by file over the pending changeset in your reply.
- **No verdict line at all** — stdout is empty, holds only stderr text, or carries no parseable `REVIEW_VERDICT` → the dispatcher exited before it could report (a bad argument, an unreadable message file, a missing `jq`, a tool that died). **Treat this exactly as `no-verdict`: nothing is committed.** Report what the output did say, then take the same ladder. An absent result is the one case where proceeding is most tempting and least defensible: it looks like nothing went wrong precisely because nothing was reported.

**The message is under review too.** If the result carries `editedFields` for the commit message — `edit` mode, where the saved buffer *is* the message — use that edited text as the message in Step 6, overwrite the Step 3 message file with it. Adopt it verbatim: it's the user's own wording, not a comment to draft from. A `changes-requested` comment with `target: "commit-message"` is feedback on the message itself — revise the message and re-review. In a mode that can't round-trip an edited message (`capabilities.editableCommitMessage: false`, which is every diff viewer), keep the drafted message unless a comment asks to change it.
