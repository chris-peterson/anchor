### When the review didn't grade it (or there's no CR yet)

Three cases land here: no tool is installed, a review that came back without a usable verdict, and the `skip-deep-links` path where no CR will exist to write to.

Walk the ladder in `<anchor-root>/guides/review-fallback.md` with `DESC_DRAFT_PATH` as the artifact. This skill's artifact is a drafted document, so the changeset walk doesn't apply; the document rungs do.

Then ask how to proceed with structured choices when the host supports that
(header `Disposition`), or directly otherwise, with options in this order:

- **Yes (write)** *(default)* — push the description to the open CR.
- **No (copy only)** — leave it for the user to paste into the web UI themselves.
- **Edit** — say what to change in chat; revise and re-present.

### Open the CR and write it

Reached on an `approved` review, or on **Yes (write)** from the no-tool fallback. Editing a description is reversible, which is why the review's sign-off is enough to write on. On 401/403 or similar auth failure, surface the error and ask the user to refresh credentials — do not silently fall back to copy-only. The draft is `DESC_DRAFT_PATH`.

**1. Open the CR, if Step 1 said one is pending.** On `CR_PENDING=1`, this is where the CR first exists, and it exists carrying the text the author just approved:

```bash
bash "<anchor-root>/scripts/prepare-review.sh" --open \
  --title "<the Step 3 title>" --body-file <DESC_DRAFT_PATH>
```

It emits `CR_URL`, `CR_IID`, `CR_DRAFT`, `CR_CREATED=1`, and `DELETE_BRANCH_ON_MERGE` — act on that last one per "Branch deletion on merge". A `CR_CREATE_ERROR=` line is an auth or forge failure: surface it and stop, with the approved draft still in hand. On `CR_PREEXISTING=1` there is nothing to open; carry that CR's URL forward.

**2. Expand the deep links against the URL.** The placeholders can only become URLs once the CR has one:

```bash
bash "<anchor-root>/scripts/deep-links.sh" --expand <DESC_DRAFT_PATH> \
  --forge <FORGE> --cr-url <CR_URL> --base <DEFAULT_BRANCH>
```

It rewrites the draft in place and reports `EXPANDED=<n>`. All-or-nothing: an unresolved placeholder leaves the file untouched and exits non-zero, which means the `--check` in the output checklist was skipped or the tree moved since. Fix what it names and re-run — the CR is already open and carrying the approved prose, so nothing is lost. Skip this on `skip-deep-links`, where the draft carries no placeholders.

**3. Write the expanded body to the CR.** The `--open` above already landed the approved text, so this is the same write in both cases: it replaces that body with the expanded one, or updates a pre-existing CR.

**Screenshots referenced by local path (GitLab) upload first.** `glab api --method POST projects/<id>/uploads --form "file=@local.png"` returns a `markdown` field pointing at a hosted URL — swap each local reference for its upload result in `DESC_DRAFT_PATH` before the write below, so the description lands with working images on the first try. See the forge cookbook's binary-upload recipe; the `-F`/`--form` distinction there is the part that bites.

- **GitHub:** `gh pr edit --body-file <DESC_DRAFT_PATH>`.
- **GitLab:** use the API form `glab api -X PUT projects/:fullpath/merge_requests/<CR_IID> -F "description=@<DESC_DRAFT_PATH>"` — `glab mr update -d` doesn't accept a file. See the bundled forge cookbook (`<anchor-root>/guides/forge-cookbook.md`) for the full canonical invocation.

When operating against a non-cwd repo these are the write path, so retarget them per "Operating against a non-cwd repo": add `-R <owner/name>` to `gh pr edit`, and substitute the URL-encoded project for `:fullpath` in the `glab api` PUT (plus `--hostname` for self-hosted).

Report the write as one line once **Label it and set the milestone** below has run — the CR URL, that the description landed, and what the metadata came out as. **No CR to write to** (`skip-deep-links`, or the user picked copy-only): print the body for them to paste into the web UI themselves.

### Label it and set the milestone

A CR sits in the same triage queues an issue does, so give it the project's own labels and, where one fits, its milestone. Read the project's label set and its open milestones rather than naming one from memory — the listing calls are in the cookbook's "Labels and milestones" — then read what the CR already carries, which is what decides how much of it is yours to set:

```bash
# GitHub
gh pr view <CR_NUMBER> --json labels,milestone

# GitLab
glab mr view <CR_IID> --output json
```

Match the change against the descriptions the repo ships on its labels and apply the ones that plainly fit and the CR is missing. `--add-label` and `--label` add, so a CR the user already labelled keeps what it has; `--milestone` **replaces** on both forges, so attach one only where the CR has none and exactly one of the open ones fits. Where several labels are plausible and only one belongs, or several milestones fit, ask with structured choices when the host supports that, or directly otherwise — no label and no milestone are both legitimate answers, and where the project defines none, set nothing and don't raise it.

```bash
# GitHub
gh pr edit <CR_NUMBER> --add-label "<label>" --milestone "<milestone title>"

# GitLab
glab mr update <CR_IID> --label "<a,b>" --milestone "<milestone title>"
```

Retarget the listing and these calls per "Operating against a non-cwd repo" the same way the write path does (`-R`, `TARGET_PROJECT` for `{owner}/{repo}` in the `gh api` milestones path, `--hostname` for self-hosted GitLab). The full flag set and the CLI gaps — `gh` has no `milestone` command, and `gh pr edit` has no plain `--label` — are in the cookbook's "Labels and milestones".
