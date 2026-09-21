## Step 6: Commit and push

Reached only on a clean review (or the message-only-amend exception, which has no tree change to review). `anchor` performs the commit **and** the push through one helper — `commit.sh` — rather than separate `git commit` / `git push` calls: it's a single allowlistable invocation, and it owns the push-variant plumbing (the `@{u}` / `origin/<default>` probes) so that logic never runs from skill prose.

The message file already exists — the one from Step 3, or the reviewer's edited version if Step 5 returned `editedFields`. For a **squash**, write a combined message covering both the prior commit and the new changes to that file first. Then launch the helper with the shape chosen in Step 4:

- **New commit** → `--mode new --message-file <path>`
- **Squash** → `--mode amend --message-file <path>`; add `--force-with-lease` when `SQUASH_FORCE_PUSH=1` (HEAD is pushed).
- **Message-only amend** (the `ALLOW_MESSAGE_AMEND` exception) → `--mode amend --message-file <path> --force-with-lease` (a ready CR's HEAD is pushed); surface the force-push as the explicit Step 4 choice first.
- **Push-existing** (Step 1 found nothing staged but unpushed commits) → `--mode push-existing` (no message file — there's no commit to make).

```bash
bash "<anchor-root>/scripts/commit.sh" --mode new --message-file <path> --path <p> [--path <p>...]
```

Carry the **same `--path` list** through from Steps 1 and 5, so the commit holds exactly what was reviewed. It scopes the commit as well as the staging: a path someone else staged stays staged rather than riding into your commit. The message-only amend is the one call that takes no `--path` — there is no tree change to scope, and `--amend` keeps every file the commit already carried.

`commit.sh` picks the push variant itself — `-u origin <branch>` for a branch with no upstream, plain `git push` otherwise, `git push --force-with-lease` when you pass `--force-with-lease`. It also **refuses to commit onto the default branch** unless you pass `--allow-default-branch`; the Step 4 branch guard means you're normally already on a feature branch, so pass that flag only for the deliberate "commit to `<default>`" case the user chose there. Target a non-cwd checkout with `--repo <checkout>`, same as the other helpers.

Read the helper's stdout — `COMMIT_SHA`, `BRANCH`, `PUSH_MODE`, and `PUSHED=ok` on success. Report the outcome and nothing more — `Committed <COMMIT_SHA>, pushed to <BRANCH>` — followed by any comments an `approved` review left unaddressed. If the push is rejected (non-fast-forward, protected branch, auth), `commit.sh` leaves git's error on stderr and exits non-zero; surface that and stop rather than retrying or force-pushing without the lease.

**The forge's own "create a pull request" link is not the handoff.** Pushing a new branch makes GitHub print a `Create a pull request for '<branch>'` URL, and GitLab prints its `merge_requests/new` equivalent; both are in the push output you just read. Don't relay either one. That URL opens the forge's web form, which lands the CR non-draft, with the project template's checklist intact and no Review guide — the shape `anchor:prepare-review` exists to replace (`<anchor-root>/rules/use-forge-clis.md`). Where the next step comes up, name the skill: **`anchor:prepare-review` opens the CR against the branch this just pushed.**

## Step 7: Report the pipeline the push triggered

The push is what starts CI, so this flow is holding the answer to whether the commit went green — don't leave the branch pushed-but-unverified and make the user think to ask. Reached only on a successful push (`PUSHED=ok`); a rejected push has no pipeline to watch.

The watch blocks while it polls, so launch it with the host's background/session
mechanism immediately after reporting the commit, retain its handle, and read
its captured stdout through that mechanism when it completes:

```bash
bash "<anchor-root>/scripts/pipeline-after-push.sh" --skill commit
```

Nothing about *whether* to watch is decided here — the helper owns it:

- **`PIPELINE_WATCH=skipped`** → `PIPELINE_WATCH_REASON` says `config-off` (a config key turned it off) or `already-reported` (every run for this commit has been reported already). Either way there is nothing to report; end the flow silently.
- **`PIPELINE_WATCH=ran`** → the same `KEY=value` lines `anchor:pipeline` reads follow it. Report them following `<anchor-root>/templates/pipeline-report.md`, including its "After a push" notes.

Retarget it the way you retargeted `commit.sh` (`--repo`). The commit is already reported, so this never holds the flow open — the pipeline report lands when the watch settles.
