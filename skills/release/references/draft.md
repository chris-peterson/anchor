## Step 2: Read what is shipping

Read the range the recon block resolved (`RELEASE_RANGE`) — both the log and the
diff, because a commit's subject is what the author called it and the diff is what
it did:

```bash
git log <RELEASE_RANGE> --oneline
git diff <RELEASE_RANGE> --stat
git diff <RELEASE_RANGE>
```

Sort each meaningful change into one bucket. A change can touch several; pick the
most significant.

- **Breaking** — a removed or renamed public surface, a changed default that
  breaks existing callers, behavior that requires consumers to act.
- **Features** — new capability: a command, endpoint, option, flag.
- **Fixes** — corrected behavior, a fixed regression.
- **Other** — docs, tests, refactoring, CI. Summarize briefly rather than
  enumerating.

`RELEASE_LAST_REF_KIND` says what the range is anchored to: `tag` (a real prior
release), `bump-commit` (no tags — the last commit that moved the version), or
`root` (nothing has ever shipped, so this is a first release). On `root`, say that
this is the first release rather than describing the whole history as changes.

## Step 3: Decide the version

Apply [semver](https://semver.org) to `RELEASE_VERSION`: any breaking change →
major; otherwise a new feature → minor; otherwise → patch.

Three cases are the author's decision, not the skill's. Put each through the
host's structured question mechanism when available, or ask directly otherwise,
with the recommendation first:

- **A major bump.** Breaking changes make it mechanical, but declaring one is a
  consumer-facing statement. Name what breaks and confirm.
- **`RELEASE_VERSION_BUMPS=0`.** The version has never moved, so this repo hasn't
  opted into per-release versioning — starting is a change of convention. Ask
  (start versioning at the recommended bump / keep the existing no-bump
  convention); don't default to a bump.
- **`RELEASE_CHANGELOG_HAS_CURRENT=1`.** The current version already has a
  changelog section, so it looks already shipped. Releasing that same version
  again is usually a no-op that writes nothing — confirm the next version rather
  than accreting into a section users already have. Never rewrite a shipped
  section's bullets.

## Step 4: Draft the notes

Write the notes for someone who *uses* the project and never reads its diffs.
Lead each bullet with the effect, not the edit:

- Not "add `--timeout` flag to `run`" → "commands can be given a timeout, so a
  hung call fails instead of blocking".
- Not "refactor `AuthService` to rotate tokens" → "tokens rotate automatically,
  so sessions stop expiring mid-request".

Use the categories from Step 2 as `###` sections, omitting empty ones, under a
heading naming the new version. Where a breaking change is present, its section
goes first and says what the consumer must change.

### Honor `anchor.*` config

Read the project + global keys once — `git config --get-regexp '^anchor\.' 2>/dev/null` — and match the names case-insensitively (`--get-regexp` lowercases them). Absent keys keep `anchor`'s defaults; never invent a value.

- **`anchor.releaseVerbosity`** — an integer 1–100 setting where the notes sit between brevity and thoroughness. **Unset behaves as `10`** — the lowest of `anchor`'s four verbosity defaults, which descend as the audience widens (issue `75` → commit `50` → CR `25` → release `10`). Release notes have the widest audience of anything `anchor` writes, and most of that audience is reading to find out whether this release affects them. Clamp an out-of-range or non-integer value into the 1–100 band and say so once rather than failing the draft.

  **It shortens entries; it never drops one.** Every change in scope has its bullet at `1` as it does at `100`, and a breaking change keeps its migration steps at every setting — a reader who never learns a change shipped is a reader the notes failed. Work down this order and stop where the draft balances where the setting asks: the rationale for a change → the consequences a reader can infer from the effect you already stated → each bullet down to its floor, the change as its effect on someone using the project. At the default that floor is most of what's left, which is the intent.

Two conventions to honor: the loaded-framing discipline in
`<anchor-root>/guides/loaded-framing.md` (notes state what changed, not
how hard it was or how little it touched), and the forge's markdown quirks in
`<anchor-root>/guides/markdown-gotchas.md` (a release body renders as
forge markdown). Write the notes to `RELEASE_NOTES_PATH` from the recon block —
every consumer below takes them by file, never as an inline escaped string.

## Step 5: Publish along the model's path

Read the matching section of `<anchor-root>/guides/release-models.md`
before writing anything. The two families differ in *what gets reviewed*, because
they differ in where the notes end up.

Which family a model belongs to is decided by **where the notes end up**, not by
what fires the publish: `release-triggered` and `tag-triggered` put them in the
published body, `bump-commit` and `dispatch-triggered` put them in a commit.
