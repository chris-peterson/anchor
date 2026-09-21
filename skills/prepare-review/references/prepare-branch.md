### Get to a reviewable, pushed commit (`NEEDS_BRANCH` / `NEEDS_COMMIT` / `NEEDS_PUSH`)

**prepare-review is meant to run from any state.** A CR needs a commit on a feature branch that is **ahead of the default branch and pushed** — opening the draft is a pure forge operation on the pushed branch, since `anchor:commit` now does the push. When that state doesn't exist yet, the script says so (instead of letting `glab mr create` / `gh pr create` dead-end on a raw *"Could not find any commits between origin/`<default>` and `<branch>`"*) and the skill chains into `anchor:commit` to get there. The cases, keyed off the block:

- **`NEEDS_COMMIT=1`, `NEEDS_BRANCH=0`** — on a feature branch, work uncommitted. Chain into `anchor:commit`: it runs its flow (tests, staging, message, the visual review) and, on a clean review, commits **and pushes**. Then re-gather.
- **`NEEDS_BRANCH=1`, `NEEDS_COMMIT=1`** — on the *default* branch, work uncommitted. Still chain into `anchor:commit` — it detects the default branch, creates the feature branch (named from the subject it drafts), commits onto it, and pushes it. Then re-gather.
- **`NEEDS_PUSH=1`** — a feature branch with commit(s) ahead of the default branch that were never pushed (e.g. committed with raw `git`). The branch just needs pushing, which is `anchor:commit`'s job now — chain into it rather than pushing here, then re-gather.
- **`NEEDS_BRANCH=1`, `NEEDS_COMMIT=0`** — on the default branch with commits that exist only on the local default branch (committed to `main` by habit, never pushed). Move them onto their own branch first, then chain into `anchor:commit` to push it. Slug the latest subject (`git log -1 --format=%s`, the convention `anchor:commit` uses), confirm the name with the user, then:

  ```bash
  git branch <slug>                    # point the new branch at the current commits
  git reset --hard origin/<default>    # rewind the local default branch to the remote
  git switch <slug>                    # continue on the feature branch
  ```

  This is safe because the local default branch was only *ahead* of `origin/<default>` — the reset drops those commits from the default branch, but they're preserved on `<slug>`. Now on a feature branch with unpushed commits, chain into `anchor:commit` to push, then re-gather.

After the branch/commit/push lands, **re-run the gather script** so it resolves the now-creatable CR:

```bash
bash "<anchor-root>/scripts/prepare-review.sh"
```

The second run is on a pushed feature branch with a commit ahead, so it returns a normal block (`NEEDS_BRANCH=0`, `NEEDS_COMMIT=0`, `NEEDS_PUSH=0`, `CR_PENDING=1`). Proceed from there into the rebase / drafting flow as usual. If it still reports `NEEDS_COMMIT=1` / `NEEDS_PUSH=1` — the user declined `anchor:commit`, or it produced nothing ahead or pushed nothing — say so and stop; don't loop.

**Why the CR is opened last (`CR_PENDING=1`).** The Review guide's deep links are drafted as `anchor:` placeholders that resolve against the diff, not against a URL — so a complete, checkable description exists before the forge has anything on it. Opening the CR is therefore the *last* step, in Step 4, with the body the author approved. Nothing carrying their name lands until they have read it. The script does **not** sniff for a "merges direct to `main`, never opens CRs" convention, because there's no reliable signal for it. One case gives way to the `skip-deep-links` path:

- **User asks not to open one** — the repo merges direct to `main` without CRs, or the CLI's default forge instance is wrong for this repo. Re-run with `--no-open` to proceed URL-free; or, if they'd rather open the draft themselves, pause until they confirm one is open, then re-run so the script resolves its URL.

(When `ON_DEFAULT_BRANCH=1`, nothing is pending either — but that routes through branch creation, not skip-deep-links; see above.)

### A reused branch name (`PRIOR_CR_IID` / `PRIOR_CR_STATE`)

Only an open CR is this run's target. Neither CLI filters its branch lookup by state, so a short topical branch name that has been used before resolves to whatever CR used it last — the script passes over a merged, closed, or locked one and reports `CR_PENDING=1` instead. When these keys are non-empty, say so in one line as part of reporting the CR Step 4 opens, so the author who expected the old one isn't left to work out why a new number appeared:

> Opened `#82`. `#57` used this branch name before and is merged, so it isn't this run's target.

Both keys empty → say nothing; there was no prior CR to pass over. An explicit `--cr <iid|url>` resolves whatever was named regardless of state, so this never fires on that path.

### Branch deletion on merge (`DELETE_BRANCH_ON_MERGE`)

The two forges keep this in different places, so `anchor` can only set it on one of them. GitLab takes `remove_source_branch` per MR and the create call passes it. GitHub has **no per-PR field** — the only standing setting is repo-wide `deleteBranchOnMerge`, so a PR `anchor` opens carries no preference of its own. `anchor:merge` passes `--delete-branch`, which covers the branch for merges that go through it; a merge from the web UI, a bare `gh pr merge`, or auto-merge leaves the branch behind.

The key is answered by whichever call resolved a CR: recon on a pre-existing one, `--open` on the CR Step 4 creates. So when **this run opened the CR** (`CR_CREATED=1` in the `--open` block) and `DELETE_BRANCH_ON_MERGE=false`, name the gap once and offer to close it, alongside Step 4's write report. On a pre-existing CR (`CR_PREEXISTING=1`) or on `unknown`, say nothing — there's nothing this run decided.

> The source branch won't be deleted when `#7` merges — GitHub carries no per-PR setting and this repo's *"Automatically delete head branches"* is off. `anchor:merge` deletes it anyway; a merge from the web UI wouldn't. Turn the repo setting on? `[yes / no]`

On `yes`, apply the forge's remediation and report what it did:

```bash
gh repo edit --delete-branch-on-merge                     # GitHub — repo-wide, needs admin
glab api -X PUT projects/:fullpath/merge_requests/<iid> \
  -F remove_source_branch=true                            # GitLab — this MR only
```

The GitHub form changes a setting for **every** PR in the repo, which is why it needs the user's yes rather than happening at create time. It needs admin on the repo; a 403 is an authorization failure — surface it and move on with the flow (the fail-fast-on-auth rule), since the branch still gets deleted by `anchor:merge`. On `no`, proceed; don't re-ask on later runs.

Prefer the `glab api` form over `glab mr update --remove-source-branch`, whose help describes it as a *toggle* — it would turn the flag back off on an MR that already has it.
