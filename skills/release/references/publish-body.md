### `release-triggered` and `tag-triggered` — the notes are the published body

The workflow owns the bump; the notes never enter a commit, so they get the review
gate themselves.

Which mode takes the notes follows the subject. An empty
`RELEASE_NOTES_BASELINE` — nothing accrued yet — makes the notes all new, so the
`edit` mode takes them: they open in the user's editor and whatever they
save *is* the notes. A baseline with sections already in it has real hunks, so
`diff` takes it. A configured mode, or an editor with nowhere to open,
overrides that. Ask which one it will be under the **same `--skill` and the same
`--files` pair the launch uses**: the probe resolves the mode the way the launch
does, so a bare one answers for a different review and names a tool this one
will never open.

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill release --probe \
  --files <RELEASE_NOTES_BASELINE> <RELEASE_NOTES_PATH>
```

Then print the manifest the launch carries — a table naming the repo, the version
being released, the range the notes cover, the tool from that probe, and the
sections the draft holds. The shape is in
`<anchor-root>/guides/execute-quietly.md` under "show what is going under
review". Two facts from the probe belong in it:

- **`REVIEW_MODE=edit`** — the editor renders wherever its host puts it, and
  on a GUI editor that is a window behind the terminal the user is watching. A
  review silently waiting in another window is indistinguishable from nothing
  having opened, so name it.
- **`REVIEW_MODE_CONFIGURED` present** — the run is opening a different shape
  than the preference named. Name that too.
- **`REVIEW_MODE_SOURCE=subject` / `REVIEW_TOOL_SOURCE=default`** — anchor
  picked that half rather than the user. Add the configuration hint from
  `<anchor-root>/guides/execute-quietly.md` under "when anchor picked the
  tool"; `REVIEW_TOOL` names the tool about to open.

Then open the notes against `RELEASE_NOTES_BASELINE` (the empty left-hand side
the recon block created) through the **dispatcher** — not the tool directly.
It blocks until closed, so launch it with the host's background/session
mechanism, retain its handle, and read captured stdout through that mechanism;
`tail` / `$(...)` trips the command-substitution gate:

```bash
bash "<anchor-root>/scripts/review-diff.sh" --skill release --files \
  <RELEASE_NOTES_BASELINE> <RELEASE_NOTES_PATH> \
  --title 'Release notes' \
  --detail version=<NEW_VERSION> --detail range=<RELEASE_RANGE>
```

Map `REVIEW_VERDICT` as the other skills do: only `approved` proceeds — and where
it carries `editedFields` with `target: "release-notes"`, the saved buffer *is*
the notes, so publish that text verbatim rather than re-drafting from it, and
comments an approving review still left don't gate the publish — surface them
after it, and carry out one that asks for the follow-up itself (*file an issue
for this*);
`changes-requested` means fold in every comment (they're ungraded — and one whose
`target` is `file` with a diff in its body is the reviewer's own edit, read per
`<anchor-root>/guides/reviewer-edits.md`) and re-open
against the previous draft — copied aside to a sibling path with `.prev` before
the extension — so the second pass shows what the feedback changed; `incomplete`
and `no-verdict` mean the reviewer didn't grade it. A result with **no parseable `REVIEW_VERDICT`** (empty stdout,
stderr only — the dispatcher exited before reporting) reads the same way, and so
does a probe reporting nothing installed.

Every ungraded case takes the ladder in
`<anchor-root>/guides/review-fallback.md`: say what happened in one line,
then walk it with the drafted notes as the artifact. The notes are a drafted
document, so the document rungs apply and the changeset walk doesn't.

**Then confirm the publish explicitly, even after an `approved` review.** This is
the one place `anchor` keeps a second gate: a CR description is editable, but a
published release is public the instant it exists and its tag may be immutable.
State the version, the tag, and the model's consequence, and take a yes/no:

> Publishing `v1.2.0` creates the tag and fires `.github/workflows/release.yml`,
> which owns the version bump and changelog. Proceed? `[yes / no]`

On `yes`, publish — the notes by file, never `--generate-notes` (a generated body
lands unrelated prior CRs in the changelog the workflow writes). The two models
publish differently:

- **`release-triggered`** — create the forge release with the notes as its body
  (the cookbook's "Publish a release"). Creating it makes the tag. Leave the
  target at its default, the default branch's tip, which the recon block has
  already established HEAD to be (`RELEASE_ON_DEFAULT=1`, `RELEASE_UNPUSHED=0`);
  reach for `--target` / `--ref` only to tag a different commit, and pass the
  full 40-char sha there, because GitHub rejects an abbreviated one.
- **`tag-triggered`** — the tag *is* the trigger: annotate it with the notes and
  push it as its own step (`git tag -a v<X.Y.Z> -F <RELEASE_NOTES_PATH>` then
  `git push origin v<X.Y.Z>`), so a failed push doesn't leave a local-only tag
  that looks published. Add a forge release afterward only where the repo already
  publishes them.

On a 401/403, surface it and ask for fresh credentials; do not retry or reach for
another path.

**The create returning a URL is not the finish line.** Two follow-throughs, both
easy to drop precisely because the publish already succeeded:

1. **Watch the workflow to a terminal state** — it still has to bump, write the
   changelog, and commit, and a red run leaves a published release with no
   changelog. Delegate to `anchor:pipeline`, which watches in the background and
   runs silently under an orchestrator. Hand it the workflow by name
   (`--workflow <RELEASE_WORKFLOW>`) and watch *before* the pull below: this run
   belongs to the commit that was tagged, and it shares that commit with whatever
   the merge already ran, so naming the workflow is what makes the verdict the
   release's.
2. **Fast-forward the local checkout onto the workflow's commit** —
   `git pull --ff-only`, once the run is green. Do it; don't offer it. That commit
   carries generated content, so skipping it leaves the tree missing files and the
   next push rejected as non-fast-forward.
