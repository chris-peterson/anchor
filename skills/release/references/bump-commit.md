### `bump-commit` — the bookkeeping is a commit

Here the notes land *in the repo*, so they are reviewed as part of the commit
rather than on their own — `anchor:commit` opens the whole bookkeeping diff for
review before committing, and a separate notes review would ask the same question
twice.

1. **Bump the version.** Edit `RELEASE_MANIFEST_SOURCE` when it's set — it is the
   version source behind the shipped manifest — then run
   `RELEASE_MANIFEST_REGEN` when that value is non-empty. Otherwise edit
   `RELEASE_MANIFEST`. Read the file with the host's file-reading mechanism
   before editing so the change lands without a retry.
2. **Write the notes into the changelog.** When `RELEASE_CHANGELOG_UNRELEASED=1`,
   retitle that section to the new version rather than inserting a section above
   it — a fresh one leaves a duplicate empty `Unreleased` heading. Reconcile its
   existing bullets against the range while there.
3. **Shape the commit to `RELEASE_BUMP_CONVENTION`** (`standalone` / `fold` /
   `mixed` — the guide has the per-value call), then hand off to
   `anchor:commit`, which runs the tests, reviews the diff, writes the message,
   and pushes. Don't hand-roll `git commit` / `git push` here.
