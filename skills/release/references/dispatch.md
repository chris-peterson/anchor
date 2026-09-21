### `dispatch-triggered` — the notes are committed, then the workflow runs

The workflow owns the bump, the tag, and the published body; it reads the notes
out of the changelog, so they have to be committed before it starts. That puts
them in a commit — reviewed there, like `bump-commit`, which is why
`RELEASE_NOTES_BASELINE` is empty and there is no separate notes review.

1. **Write the notes into the changelog's accruing section.** Where
   `RELEASE_CHANGELOG_UNRELEASED=1`, fill that section and **leave its heading
   alone** — the workflow retitles it to the version it derives. Reconcile the
   bullets already in it against `RELEASE_RANGE`; they may predate later changes
   in the same release.
2. **Do not bump the manifest or its source, and do not tag.** Those are the
   workflow's, and doing them here lands a commit that fights its own.
3. **Land the notes through `anchor:commit`**, which runs the tests, reviews the
   diff, writes the message, and pushes. The workflow builds from the remote, so
   the push has to land before the dispatch.
4. **Confirm the dispatch explicitly**, the same second gate the published-body
   models get and for the same reason — the run publishes, and its tag may be
   immutable. State the workflow, the level, and what the run owns:

   > Dispatching `.github/workflows/release.yml` with `bump=minor` fires the run
   > that derives `v1.8.0`, retitles the changelog section, commits, tags that
   > commit, and publishes. Proceed? `[yes / no]`

5. **Dispatch it**, passing the level by the input's own declared name — the
   recon block resolved it, so don't assume `bump`:

   ```bash
   gh workflow run <RELEASE_WORKFLOW> -f <RELEASE_DISPATCH_BUMP_INPUT>=<level>
   ```

   Where `RELEASE_DISPATCH_INPUTS` lists inputs beyond the level, ask rather than
   leaving a required one unset — a dispatch missing one fails before the run
   starts. Where `RELEASE_DISPATCH_BUMP_INPUT` is empty, the workflow declares no
   input that carries a level: report the inputs it does declare and ask which to
   pass rather than guessing a name.

   On GitLab there is no dispatch equivalent for a tag-gated pipeline; a repo
   whose docs describe a manual pipeline run is the "path no model covers" case
   in Step 1 — say what the doc says and stop.

6. **Then follow through, exactly as the published-body models do.** `gh workflow
   run` exits as soon as the run is queued, so nothing is released yet:

   - **Watch the run to a terminal state** via `anchor:pipeline`, naming the
     workflow (`--workflow <RELEASE_WORKFLOW>`). A red run leaves the release
     unmade, and the dispatch's own success says nothing about it.
   - **Fast-forward the local checkout** — `git pull --ff-only` — once it is
     green. The run pushed the bump commit and the tag; do the pull, don't offer
     it.
