### Edit

The review is the preferred edit surface but **optional** — it runs when a review tool is available. Which one follows the subject: filing a new issue leaves `<current-path>` empty, so the body is all new and `edit` mode takes it — it opens in the user's editor and whatever they save *is* the body. Updating an existing issue has a current body to diff against, so [revdiff](https://revdiff.com) takes it and the user comments where you fold the comments in. A configured tool, or an editor with nowhere to open, overrides that. Open the current body vs. the draft (when updating) or the draft alone via the dispatcher, using the host's background/session mechanism and retaining its handle so it doesn't hold the turn open:

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill issue --files \
  <current-path> <draft-path> \
  --title 'Issue body — proposed edits' \
  --detail repo=<repo>
```

`--skill issue` tells the adapter the artifact is an issue body; the mode itself follows the subject. Ask which one it will be before launching, under the **same `--files` pair the launch uses** — the probe resolves the mode the way the launch does, so a bare one answers for a different review and names a tool this one will never open:

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill issue --probe \
  --files <current-path> <draft-path>
```

Then say in one line where the draft is about to appear:

- **`REVIEW_MODE=edit`** — the editor renders wherever its host puts it, and on a GUI editor that is a window behind the terminal the user is watching. A review silently waiting in another window is indistinguishable from nothing having opened, so name it.
- **`REVIEW_MODE_CONFIGURED` present** — the run is opening something other than what the preference named. Name that too.
- **`REVIEW_MODE_SOURCE=subject` / `REVIEW_TOOL_SOURCE=default`** — anchor picked that half rather than the user. Add the configuration hint from `<anchor-root>/guides/execute-quietly.md` under "when anchor picked the tool"; `REVIEW_TOOL` names the tool about to open.

Say it as part of the manifest the launch carries — a table naming the repo, the issue (its number and title when updating one), the tool from that probe, and the sections the draft holds. The shape is in `<anchor-root>/guides/execute-quietly.md` under "show what is going under review". Nothing else about the launch is output; after the table, the next thing you say is the verdict.

Read the verdict back through the host's command-session mechanism (not `tail` /
`$(...)`). Only `REVIEW_VERDICT` `approved` is approval; an `approved` result carrying `editedFields` with `target: "issue-body"` — `edit` mode, where the saved buffer *is* the body — means file that text verbatim rather than re-drafting from it; an `approved` result can still carry comments, which don't gate the write — surface them after it, and carry out one that asks for the follow-up itself (*file an issue for this*); `changes-requested` carries comments in `REVIEW_OUTPUT.comments` to fold in before re-presenting — ungraded, so every one of them, and one whose `target` is `file` with a diff in its body is the reviewer's own edit rather than an annotation (`<anchor-root>/guides/reviewer-edits.md`), and the re-open's left-hand side is the previous draft (copied aside to a sibling path with `.prev` before the extension) so the second pass shows what the feedback changed; `incomplete` / `no-verdict` mean the review didn't complete — surface what happened and take the fallback ladder rather than treating silence as approval. A result that carries **no parseable `REVIEW_VERDICT` at all** (empty stdout, stderr only — the dispatcher exited before reporting) is the same case: report what the output showed and verify with the user; nothing is filed on an unverified result. (The full verdict contract matches the `prepare-review` skill's Step 4.)

Ungraded for any reason — nothing installed, or a review that came back without a verdict — walks the ladder in `<anchor-root>/guides/review-fallback.md` with the drafted body as the artifact. It is a drafted document, so the document rungs apply and the changeset walk doesn't.
