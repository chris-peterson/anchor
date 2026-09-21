## Step 3: Look at every change

Open the whole range in the diff viewer. This step is not skippable and the
range is not filtered: a review that saw part of a change and signed off on all
of it is worth less than no review, and the only way the user can stand behind
findings is to have seen what produced them.

Ask the dispatcher how this review resolves — it takes this skill's mode key
over the umbrella one, falls back to what the subject picks, and considers only
tools that can actually open:

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill review --probe
```

Two answers mean **don't launch** — this skill's subject is a changeset, and
neither reaches one:

- **`REVIEW_AVAILABLE=0`** — nothing usable is installed.
- **`REVIEW_MODE=edit`** — edit mode edits a single drafted artifact and refuses
  a diff-only review (DIFF-15), so launching it would report a configuration
  error instead of showing the CR. A CR's changeset is a diff subject, so this
  answer means something is wrong rather than something is configured: say the
  skill needs a viewer and what the probe reported. `REVIEW_EDIT_AVAILABLE` is
  about a different question and doesn't rescue it here.

Either way, go to the changeset rung of
`<anchor-root>/guides/review-fallback.md` — file by file, in your reply —
rather than launching into a refusal.

Otherwise launch it with the host's background/session mechanism and retain its
handle — the viewer blocks until closed:

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill review \
  --mode <REVIEW_MODE> [--repo <path>] <DIFF_RANGE> \
  --title '<CR_TITLE>' \
  --detail CR=<CR_URL> --detail author=<CR_AUTHOR> --detail files=<CHANGED_FILES>
```

The `--title` / `--detail` overrides matter here: without them the header
describes the local `HEAD`, which on a CR you didn't write is somebody else's
change labelled with your last commit.

**Print the manifest as you launch** — a table of the CR's changed files with
their `+`/`−` counts, plus the CR number, its author, and the tool. This is
somebody else's change, so the set is what says whether you are about to review
what they asked you to. The shape is in
`<anchor-root>/guides/execute-quietly.md` under "show what is going
under review". Nothing else about the launch is output.

Read the captured result through the host's command-session mechanism. This
skill reads the verdict differently from its siblings, because here the
reviewer's comments are the *product* rather than an obstacle:

- **`changes-requested`** — the expected outcome. `REVIEW_OUTPUT.comments` are
  findings the user typed; carry them into Step 4 verbatim. One whose `target` is
  `file` with a diff in its body is a finding they typed *into the code* through
  a difftool — read it per `<anchor-root>/guides/reviewer-edits.md` and carry
  what it says, not the patch, into the summary.
- **`approved`** — every change was read and nothing was flagged. That is a real
  review with no inline findings; Step 4 still writes the summary.
- **`incomplete`** — the tool is telling you not every hunk was reviewed.
  Name what went unseen and re-open the viewer. Do not build a document over it:
  this verdict is exactly the rubber-stamp the step exists to prevent.
- **`no-verdict`** — the review did not complete. `capabilities.producesVerdict:
  false` means the tool graded nothing; `mode: "edit"` means edit mode was
  selected anyway and refused
  the changeset (DIFF-15), which the probe above catches first; otherwise read
  `raw.exitCode`. Say what happened in one line, then walk the changeset rung of
  `<anchor-root>/guides/review-fallback.md` — file by file, in your reply.
  Don't ask whether the user read the changes: this step's product *is* the
  reading, so an answer either way leaves you with no findings to carry forward.
- **No verdict line at all** — treat as `no-verdict`; absent output is never a
  completed review.

`reviewCompleteness` is `null` on a tool that cannot measure it — that means
*unmeasured*, not *complete*. The obligation this step carries is the one you
control: hand the viewer the entire `DIFF_RANGE`, every time.
