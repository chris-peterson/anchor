### Report the branch's pipeline

Run this once the description has landed with the host's background/session
mechanism, retaining its handle, retargeted the same way as the write path:

```bash
bash "<anchor-root>/scripts/pipeline-after-push.sh" --skill prepare-review
```

Call it whether or not this flow pushed. It gates on the runs already reported, so a CR opened on the commit `anchor:commit` just pushed and reported comes back `PIPELINE_WATCH=skipped`, `already-reported`, and nobody is told twice about one pipeline. Two cases still report: a force-pushed rebase is a *new* commit, and where CI is gated on the CR (`on: pull_request`), the pipeline that opening it starts is one nobody has seen — the push-time watch found nothing to report.

On `skipped`, say nothing. On `PIPELINE_WATCH=ran`, read the following lines
through the host's command-session mechanism and report them following
`<anchor-root>/templates/pipeline-report.md`.

### Set the ordering dependency (when Step 2 captured one)

If this CR must land after a predecessor CR, record the ordering on the forge once the description is written — not just in the prose line from Step 3. The full invocation and the degrade ladder live in the cookbook's "Linking an ordering dependency between CRs"; in short:

- **GitLab** — set the enforced dependency: `glab api -X POST "projects/:fullpath/merge_requests/<CR_IID>/blocks" -F blocking_merge_request_iid=<predecessor-iid>` (add `-F blocking_project_id=<id>` when the predecessor is in another project). **Detect by attempt, don't pre-probe:** `201` linked · `409` already linked (fine) · `404` the instance predates the API (< 17.5) · `403` not Premium/Ultimate or no permission. On `404`/`403`, fall back to prose — confirm the Step 3 `Depends on !<iid>` line is present and tell the user the ordering isn't enforced (they can set it in the UI if the instance supports it).
- **GitHub** — no native cross-PR dependency exists; the Step 3 `Depends on #<num>` line is the only signal. State that GitHub won't block the merge on it.

No predecessor captured (a single CR, or an independent one) → skip this entirely.

> **On GitHub, one web-UI step remains:** `gh` exposes no equivalent upload endpoint, so screenshots embedded in the description must be dragged into the forge editor. After **Yes (write)** lands the body, open the CR in the browser, drop each PNG, and re-save — GitHub rewrites the local paths to hosted URLs. **On GitLab this step doesn't exist** — the "Write it" step above already uploaded each screenshot through `glab api --form` and wrote the description with hosted URLs, so there's nothing left to drag in.

### Announce what this run did

The last step of the phase, once every mutation above has landed. Siblings in the suite react to what anchor says it did; nothing here reads the output, and a machine where nobody is listening pays nothing for it.

**Exactly one announcement per run**, chosen by `CR_CREATED` from Step 1's block:

- **`CR_CREATED=1`** — announce nothing. `prepare-review.sh` already announced `cr.created` when it opened the CR, and setting up a CR this run just opened is not an update to it.
- **`CR_CREATED=0`** — the CR existed before this run and this run changed it:

```bash
bash "<anchor-root>/scripts/announce.sh" cr.updated \
  "uri=<CR_URL>" "title=<CR_TITLE>"
```

One announcement for the whole phase rather than one per mutation: a run that wrote a description, set labels, and attached a milestone changed one thing as far as a subscriber is concerned, and emitting per-mutation would make every consumer debounce. Skip it entirely where nothing was written — copy-only, or `skip-deep-links` with no CR to write to.

The publisher exits 0 on every path, so this can never turn a CR that landed into a tool call that failed. The contract it satisfies is in the marketplace repo at [`authoring/plugin-contract.md`](https://github.com/chris-peterson/claude-marketplace/blob/main/authoring/plugin-contract.md).
