### Open the review

The description review runs when a review tool is available. Ask the dispatcher which one — it resolves this skill's key over the umbrella one and then the default the *subject* picks, considering only tools it can actually open. **Give the probe the same `--files` pair the launch will get**: the default reads the left-hand side, so a bare probe answers for a review nobody is about to open.

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill prepare-review --probe \
  --files <CURRENT_DESC_PATH> <DESC_DRAFT_PATH>
```

- `REVIEW_MODE=edit` — what an empty `CURRENT_DESC_PATH` gets: no CR holds a description yet, so there is nothing to diff and the draft is all new. It opens in the user's editor and whatever they save *is* the description.
- `REVIEW_MODE=diff` (or another viewer) — the CR already has a description, so the two sides make real hunks; or the user configured a viewer, or no editor was reachable and an installed one stood in. The user comments and you fold the comments in.
- `REVIEW_AVAILABLE=0` — nothing usable; skip to the fallback ladder below.
- `REVIEW_MODE_CONFIGURED` present — the run is opening a different shape than the preference named, because the one it named has nowhere to open. Say which one you're opening in one line, so it isn't discovered as a surprise window.
- `REVIEW_MODE_SOURCE` / `REVIEW_TOOL_SOURCE` — where each half of the choice came from. `subject` on the first, or `default` on the second, means anchor picked it and the user has no preference on file, which is the hint the manifest carries (`<anchor-root>/guides/execute-quietly.md`, "when anchor picked the tool"). `REVIEW_TOOL` names the tool about to open, so the line can say what it would replace.
- `REVIEW_EDIT_AVAILABLE=0|1` — whether the fallback ladder may offer the editor rung. Carry it forward; it costs nothing here and it's the difference between offering a route that works and one that dead-ends.

Pass what it returned to the launch (`--mode <REVIEW_MODE>`) so the review opens in the tool the probe found rather than re-resolving the config.

With a tool available, open the draft through the **dispatcher** — not the tool directly; the dispatcher builds the header and prints the normalized result on its stdout. The tool blocks until it's closed, so launch with the host's background/session mechanism and retain its handle; a foreground call holds the turn open until the command timeout:

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill prepare-review --mode <REVIEW_MODE> --files \
  <CURRENT_DESC_PATH> <DESC_DRAFT_PATH> \
  --title 'CR description' \
  --detail branch=<BRANCH> --detail CR=<CR_URL>
```

`CURRENT_DESC_PATH` is the left-hand side — what the forge holds now, and an empty file where no CR holds anything yet. It's context for the draft, not the subject.

**Print the manifest as you launch.** The subject here is one drafted document, so the table names the CR (number and title), the repo and branch, the tool, and the sections the draft carries — an editor window opens behind the terminal, and a review the user cannot see is one they never grade. The shape is in `<anchor-root>/guides/execute-quietly.md` under "show what is going under review". Nothing else about the launch is output. After the table, the next thing you say is the verdict, the feedback echoed back, or the one-line write result.

When the background command completes, read its captured stdout through the host's command-session mechanism — not `tail` / `$(...)`, which trips the command-substitution gate. The last lines carry `REVIEW_VERDICT` (`approved` / `changes-requested` / `incomplete` / `no-verdict`) and `REVIEW_OUTPUT` (compact JSON — the DIFF contract in `SPEC.md`). **Don't read silence as success** — only `approved` is approval:

- **`approved`** — write the draft to the CR (see "Write it" below). A result carrying `editedFields` with `target: "description"` is `edit` mode, where the saved buffer *is* the description: **that text is what you write**, verbatim, and it isn't re-presented for approval — the user just typed it. Either way the reviewer read the description and signed off, so a second chat gate asking the same question is the ceremony this step exists to remove. Surface any comments an approving review still left, after the write. One that asks for the follow-up itself (*file an issue for this*) is an instruction rather than a remark: carry it out, through `anchor:issue` where it asks for an issue.
- **`changes-requested`** — each entry in `REVIEW_OUTPUT.comments` is `{body, target, file?, startLine?, endLine?, side?}`, where `body` is the inline feedback. A comment whose `target` is `file` and whose body carries a diff is the reviewer's own edit rather than an annotation — they wrote into the review through a difftool; read it per `<anchor-root>/guides/reviewer-edits.md`, keeping the fixes and taking their question lines back out.  Comments are ungraded, so fold in every one, then re-open the review on the revised draft. Echo the comments back first (the review-feedback table in `<anchor-root>/guides/execute-quietly.md`) so the user knows they landed.
  - **The re-open's left-hand side is the previous draft, not `CURRENT_DESC_PATH`.** Copy the draft aside before revising it — to a sibling path with `.prev` before the extension — and pass that as the left. What the second pass has to show is what the feedback changed; the description the forge holds is the comparison the first pass already answered.
- **`incomplete`** — the reviewer closed with changes unreviewed: a partial pass, not approval. Ask what they want to change, then re-review.
- **`no-verdict`** — the review **did not complete**. `capabilities.producesVerdict: false` means the tool graded nothing; otherwise it closed early or errored (see `raw.exitCode`). Either way the user *may* have seen it and definitely didn't grade it: report what happened, then take the fallback ladder below. Don't silently retry — the same failure recurs.
- **No verdict line at all** — stdout empty, only stderr text, or no parseable `REVIEW_VERDICT`: the dispatcher exited before reporting (bad argument, missing `jq`, a tool that died). Treat it as `no-verdict` — say what the output did show, and take the fallback ladder below. Nothing is written to the CR on an unverified result.
