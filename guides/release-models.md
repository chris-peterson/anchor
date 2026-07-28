# Release models

A repo's **release model** is the answer to one question: *who owns the version
bump?* `/anchor:release` reads the model from
`scripts/release-recon.sh` (`RELEASE_MODEL`) and takes the matching path below.
Exactly one applies per repo.

Getting the model wrong is the expensive mistake in a release, and it fails
*after* publishing rather than before: hand-editing a manifest whose CI workflow
also bumps it lands two commits that fight, and the collision surfaces once the
release is already out.

| Model | Who bumps | The publish step |
|---|---|---|
| `release-triggered` | the CI workflow | create a release on the forge |
| `tag-triggered` | the CI workflow | push an annotated tag |
| `bump-commit` | this skill, as a commit | the commit (and its push) |
| `no-version-artifact` | nobody | the merge already was the release |

## `release-triggered` — CI fires on a published release

The shape: `.github/workflows/*.yml` with `on: release: types: [published]`. The
workflow bumps the manifest, prepends the release body into the changelog,
commits the bump, and (sometimes) notifies a downstream catalog. The recon block
names the file in `RELEASE_WORKFLOW`.

**Do not bump the manifest, regenerate it, or edit the changelog.** Those are the
workflow's commit. The work here reduces to two steps: push clean feature commits
to the default branch, then create the release with the real notes as its body.

This sequence is deterministic — run it. Re-deriving "who owns the bump" by
reading the workflow and whatever reusable workflow it calls spends a lot of
reasoning on a settled process; the recon block already answered it.

Five traps:

- **Forge-generated notes poison the changelog.** The workflow proxies the
  release body verbatim, so a generated "what's changed" list lands a run of
  unrelated prior CRs in the new changelog section. Write the real categorized
  notes into the body.
- **Creating a release needs `Contents: write`.** Pushing over SSH works without
  it, so the gap stays hidden until the publish returns 403. On a 401/403, stop
  and ask for credentials rather than retrying — the forge cookbook's
  "Etiquette: fail fast on auth".
- **Releasing the current version can silently no-op.** A changelog step that
  skips when a section for that version already exists means re-releasing the
  version the descriptor already holds writes nothing, and the workflow's commit
  step then finds nothing to commit — only the downstream notification fires. To
  get a real changelog section, release a *new* version. Most likely on a repo
  whose descriptor moved during development but was never released.
- **An existing changelog section can be incomplete.** The same skip-if-present
  behavior ships a section hand-written when one CR merged, silently omitting
  everything else that landed since. "The section exists" is not "the changelog is
  complete" — diff it against the commits in `RELEASE_RANGE` and confirm every
  user-facing commit is represented. If it's short, surface the gap; the author
  may intend to omit internal work.
- **A cross-repo notification needs a token scoped to the *other* repo.** When
  the workflow's last step dispatches to a separate catalog/registry repo, a
  default job token is scoped to the current repo and cannot dispatch across —
  the release is created but the downstream step goes red. Across a family of
  repos sharing a copied workflow, this drifts: one repo still uses the default
  token where its siblings use a scoped secret.

**The publish is not done when the create command returns a URL.** Creating the
release only *starts* it. Two follow-throughs:

1. **Watch the workflow to a terminal state.** The release exists the instant the
   command returns, but the bump, changelog, and dispatch can still fail — and a
   red workflow leaves a *published* release with no changelog. Delegate the wait
   to the pipeline helper rather than hand-rolling a poll loop.
2. **Fast-forward local state onto the workflow's commit.** The workflow pushes
   its bump commit to the default branch, so the local checkout is now behind.
   That commit carries *generated* content (a bumped manifest, a regenerated
   descriptor, a prepended changelog) — skipping the pull leaves the tree missing
   files, so the next branch starts from a base that lacks them and the next push
   is rejected as non-fast-forward. Pull as the release's closing step.

## `tag-triggered` — CI fires on a tag push

The shape: `on: push: tags:` on GitHub, or a `$CI_COMMIT_TAG`-gated GitLab
pipeline (GitLab has no release-published event, so a tag is the trigger there).

Same division of labor as `release-triggered` — the workflow owns whatever it
bumps — with the tag replacing the forge release as the trigger. Whether the
manifest bump precedes the tag or the workflow performs it is repo-specific: read
`RELEASE_BUMP_CONVENTION` and the prior release's commits before writing
anything. Tag from the commit that is shipping, and push the tag as its own step
so a failed push doesn't leave a local-only tag that looks published.

## `bump-commit` — no release CI, so the bump is a commit here

Bump the version, update the changelog, commit, push. Three things decide the
shape of that commit.

**Bump the source, not a generated manifest.** When `RELEASE_MANIFEST_SOURCE` is
set, the manifest is generated from that descriptor: edit the descriptor and run
`RELEASE_MANIFEST_REGEN`. A hand edit to the generated file drifts from its
source, and a sync check rejects the commit. Regeneration may also rewrite fields
the committed file lacked — that fuller output is the correct generated form, not
scope creep, so stage it as-is.

**Match the repo's commit convention** (`RELEASE_BUMP_CONVENTION`):

- `standalone` — prior bumps stood alone as their own commit. Commit the feature
  with its notes, then a separate bump commit doing the manifest bump and the
  changelog edit.
- `fold` — prior bumps rode the feature commit. One commit carries both.
- `mixed` — the repo has done both. Let *this* release's shape decide: one commit
  worth of work can fold; a release spanning several commits (a feature plus a
  review-driven fix) has no single commit to fold into, so a standalone bump
  commit is the clean fit.
- `none` — see the never-versioned carve-out below.

Deciding this *before* committing matters: guessing wrong forces a reset and a
fiddly re-split, because changelog edits interleave feature content with bump
content and file-level staging can't separate them after the fact.

**Rename an accruing `Unreleased` section rather than inserting above it.** When
the changelog already has one (`RELEASE_CHANGELOG_UNRELEASED=1`), retitle it to
the new version — a fresh section leaves a duplicate empty `Unreleased` heading
behind. Reconcile its bullets against `RELEASE_RANGE` while there; they may
predate later changes in the same release.

## `no-version-artifact` — nothing to bump

No manifest at all: infrastructure-as-code, a docs or content repo, a repo whose
deploy is driven by the merge itself. There is no version to recommend and no
publish step to run. Say so plainly, report what the range contains, and stop —
this is the correct outcome, not a gap. Where the merge triggers a deploy, the
useful thing to add is the deploy's state, which the pipeline helper can report.

## Two carve-outs that cut across every model

**A never-versioned repo is the author's call.** `RELEASE_VERSION_BUMPS=0` means
the version has never moved (a manifest still at its scaffolded value). Starting
per-release versioning is a change of convention, not a mechanical step — surface
the fork (start versioning now vs. keep the existing no-bump convention) rather
than defaulting to a bump. "The last change didn't bump either" is context, not
an argument either way.

**Never let a version go backward in a diff someone reviews.** If the version was
already bumped during feature work and the repo's convention wants a standalone
bump commit, the tempting fix is to revert the manifest for the feature commit
and re-apply it after. Don't: a `1.4.0 → 1.3.0` staged diff reads as a regression
at a glance and alarms the reviewer even though the end state is right. Either
keep the bump and shape the commits around it, or back it out *before* anything is
staged. The end state being correct doesn't redeem the intermediate diff.
