## Step 1: Establish the release model

One recon pass supplies every fact this skill would otherwise derive by hand.
Read it, don't re-derive it — re-running these git and CI reads by hand is the
waste this helper exists to remove:

```bash
bash "<anchor-root>/scripts/release-recon.sh"
```

`RELEASE_MODEL` decides the whole path. Read the matching section of
`<anchor-root>/guides/release-models.md` — it carries the per-model
procedure and the traps each one hides:

| `RELEASE_MODEL` | Who bumps | What Step 5 does |
|---|---|---|
| `release-triggered` | the CI workflow (`RELEASE_WORKFLOW`) | create a forge release; never touch the manifest |
| `tag-triggered` | the CI workflow | push an annotated tag |
| `dispatch-triggered` | the CI workflow (`RELEASE_WORKFLOW`) | commit the notes, then dispatch it with the level; never touch the manifest |
| `bump-commit` | this skill | bump, edit the changelog, commit |
| `no-version-artifact` | nobody | nothing — report and stop |

### The repo outranks the inference

`RELEASE_MODEL` is inferred from the repo's CI triggers, which is the right
answer only for a repo that hasn't said otherwise. A repo *is* the authority on
how it publishes, so where it states that, the statement wins.

`RELEASE_PUBLISH_DOCS` names the docs that state one — a comma-separated list of
existing files, empty when none of them mention releasing. **Empty is the common
case: act on `RELEASE_MODEL` and don't raise it.** Where it names a file, read
that file for the publish path before doing anything else, and:

- **The two agree** — proceed on the model; say nothing.
- **They disagree** — follow the repo and say so in one line (*"AGENTS.md says
  releases are dispatched, so taking that over the inferred `bump-commit`"*).
  Don't argue the inference; the doc is the author writing down what they do.
- **The doc describes a path no model covers** (a script, a separate release
  repo, a person to ask) — say what it says and stop rather than substituting the
  nearest model.

This is a targeted read of a named file for one fact, not a general instruction
to reason from the whole document.

Two states end the run here, and both are correct outcomes rather than failures:

- **`no-version-artifact`** — no manifest, so there is no version to recommend and
  nothing to publish. The merge already was the release. Say so, summarize what
  `RELEASE_RANGE` contains, and stop. Where the merge triggers a deploy, add its
  state via `anchor:pipeline` rather than inventing a publish step.
- **`RELEASE_COMMITS=0`** — nothing has landed since `RELEASE_LAST_REF`. Report
  that the last release is current and stop; don't manufacture a version.

Two states need surfacing before going further:

- **`RELEASE_DIRTY=1`** — uncommitted changes. A release describes committed work.
  Surface the dirty tree and ask whether to commit it first (`anchor:commit`) or
  release what's committed.
- **`RELEASE_UNPUSHED` > 0 with `RELEASE_ON_DEFAULT=1`** — local commits the remote
  hasn't seen. On every model where a workflow owns the bump it builds from the
  remote, so publishing now would ship without them. Push first.
