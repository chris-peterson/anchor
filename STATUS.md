# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).

**Last audit:** 2026-10-01
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 1.15.2
**Coverage:** 294 Covered, 36 Partial, 11 Missing (341 total)

The implementation is the plugin itself — the skill prompts under
`skills/`, the ambient rules under `rules/`, and the helper scripts under
`scripts/`. Every requirement was read against that source on 2026-09-16, so a
row's status is what the code does rather than what the requirement asks for.
Where the two disagree, the divergence is under Open / Needs Decision below.

## Status by category

| Prefix | Count | Status | Notes |
|--------|------:|--------|-------|
| TARGET-01..11 | 11 | 6 Covered, 5 Partial | Target resolution — `scripts/resolve-target.sh`, each `skills/*/SKILL.md` "Target repo"; every skill routes a name argument through `resolve-target.sh`. `--repo` is read at any argv position and an unrecognized argument is an error rather than a dropped token, so an appended retargeting flag cannot leave a helper on the cwd repo while the flow uses the target (TARGET-09) — `scripts/review-diff.sh` (context-flag pass, `expect_consumed`), `scripts/look-ahead.sh`, `tests/review-diff.test.sh`. A name resolves through the forge CLIs anchor already requires, over the repos reachable on each host `gh auth status` / `glab auth status --all` report as logged in, so no sibling plugin gates the capability (TARGET-01) — `scripts/resolve-target.sh` (`authed_hosts`, `load_hosts`). A bare name matches on the basename exactly and case-insensitively, which is what separates `cloud-toolbox` from the `pwsh-toolbox` GitLab's substring search returns alongside it (TARGET-10) — `scripts/resolve-target.sh` (`collect`, `lower`). `TARGET_LOCAL` holds the working directory's repo only when its `origin` is the repo that resolved, an unauthenticated host is skipped, and a lookup with no host to query says so rather than reporting no match (TARGET-11) — `scripts/resolve-target.sh` (`local_checkout`, `fall_back_to_cwd`) **Gaps (2026-10-01):** TARGET-01: the GitLab name search is unpaginated and the name is not URL-encoded; TARGET-03: only `commit` and `pipeline` say to re-resolve per invocation; TARGET-05: `issue`, `backlog`, `review`, `prepare-review` skip the substring fallback (needs decision); TARGET-06: only `commit` and `pipeline` carry the multi-repo check; TARGET-11: a logged-in host whose API calls fail reads as no match (`scripts/resolve-target.sh`) |
| COMMIT-01..25 (+04a, 04b, 04c, 04d, 04e, 10a; 17 retired) | 30 | All Covered | A pushed commit the review covered gets a round in its own CR's Review status section (COMMIT-25) — `skills/commit/SKILL.md` Step 6, `scripts/review-status.sh` (`record`). The pending changeset's review carries a note on each hunk a reader would ask about, seeded from the caller's where it hands some, read back as read unless edited, and listed in the manifest where the tool can't show them (COMMIT-23) — `skills/commit/SKILL.md` Steps 3 and 5, `scripts/review-explain.sh`, `guides/review-notes.md`, `tests/review-explain.test.sh`. A branch with no commit reviews against the empty tree and offers no squash (COMMIT-24) — `scripts/lib/stage-paths.sh` (`anchor_local_base`), `scripts/review-diff.sh`, `scripts/squash-check.sh`, `tests/{review-diff,squash-check}.test.sh`. Review-first commit-and-push flow (1.0), a squash's combined message written before the review (COMMIT-10a) and a message-only amend shown verbatim with its force-push (COMMIT-13), recon before tests, pipeline watch after the push (COMMIT-21), and the direct-to-default choice described as landing without a CR rather than as bypassing review (COMMIT-22) — `skills/commit/SKILL.md`, `scripts/{commit,commit-preflight,look-ahead,squash-check,pipeline-after-push}.sh`. Staging names its paths instead of adding the whole tree, stops on a path with no change at all, scopes the commit to the same set, and reports a staged path it did not stage rather than committing or unstaging it (COMMIT-04, 04a, 04b). The commit is built from a scratch index holding HEAD plus the named paths' staged entries, so each path lands as staged rather than as its working-tree copy (COMMIT-04b) — `scripts/commit.sh` (scratch-index commit), `tests/commit.test.sh`. A partly staged file is committed as its staged hunks: `--staged-path` takes it from the index without staging, and a `--path` naming one is refused with exit 67 before anything is staged (COMMIT-04d) — `scripts/lib/stage-paths.sh` (`anchor_refuse_partly_staged`, `anchor_require_staged`), `scripts/commit-preflight.sh` (`--staged-path`), `tests/commit-preflight.test.sh`. The review prints a `REVIEW_INDEX` id of the scoped paths' index entries before the tool opens, and the commit requires that id with `--path` and refuses with exit 68 when the entries no longer match it, so a `git add` after the review cannot ship unreviewed (COMMIT-04e) — `scripts/lib/stage-paths.sh` (`anchor_index_digest`), `scripts/review-diff.sh` (`REVIEW_INDEX`), `scripts/commit.sh` (`--reviewed-index`), `skills/commit/SKILL.md` Steps 5/6, `tests/{commit,review-diff}.test.sh`. Restaging the same list is safe for any mix of added, modified, deleted, and renamed paths, because a path already staged in full is skipped — so a staged deletion, or the old half of a rename, cannot make the `git add` fatal for the flows that stage their list twice (COMMIT-04c) — `scripts/lib/stage-paths.sh` (`anchor_stage_paths`, `anchor_other_staged_count`, `anchor_commit_pathspecs`), `scripts/commit-preflight.sh` (`OTHER_STAGED`), `scripts/commit.sh` (`--path`), `skills/commit/SKILL.md` Steps 1/5/6, `tests/{stage-paths,commit-preflight,commit}.test.sh` The review and the commit carry the named paths only, plus the old name of a named rename; a message-only amend commits no staged path; `AHEAD` counts against `origin/<default>` with no upstream; and a commit a git hook changed is not pushed (COMMIT-04, 04b, 04e, 05, 14) — `scripts/review-diff.sh` (`diff_paths`), `scripts/lib/stage-paths.sh` (`anchor_rename_sources`, `anchor_diff_specs`), `scripts/commit.sh` (`--only`, `reviewed_tree`), `scripts/look-ahead.sh`, `tests/{commit,commit-preflight,review-diff,review-difftool,review-edit}.test.sh` |
| PREPARE-01..20 (+02a, 03a, 06a, 10a, 10a1, 13a, 15a; 10b retired) | 27 | 26 Covered, 1 Partial | The Review status section is set aside from the review's baseline and put back when the description is written (PREPARE-20) — `scripts/prepare-review.sh` (`CR_REVIEW_STATUS_PATH`), `scripts/review-status.sh` (`carry`), `skills/prepare-review/SKILL.md` Step 4, `tests/prepare-review.test.sh`. `prepare-review`, pushed-branch only, reviews the description in the tool, opens the draft CR with the approved body and never before it (PREPARE-03) — `scripts/prepare-review.sh` (`--open`), `skills/prepare-review/SKILL.md` Step 4, `tests/prepare-review.test.sh`. Review-guide links are authored as `anchor:<path>#<token>` placeholders resolved against the changed hunks, an ambiguous or absent token halts with its candidates rather than guessing, and expansion into forge anchors runs once the CR exists and is all-or-nothing (PREPARE-10, 10a, 10b, 15) — `scripts/deep-links.sh` (`--resolve`, `--check`, `--expand`), `guides/cr-formatting.md`, `templates/cr-description.md`, `tests/deep-links.test.sh`. `--verify` stays as the backstop for a hand-built anchor and rejects a malformed line part as well as a mis-numbered one (PREPARE-15a) — `scripts/deep-links.sh` (`part_re`). A `/anchor:<skill>` mention is read as prose rather than as broken placeholder markup, so a description naming the skill that drafted it passes the check (PREPARE-10a1) — `scripts/deep-links.sh` (`stray_anchors`), `tests/deep-links.test.sh`. A bare placeholder whose token holds a parenthesis, cut at that `)`, is reported `unbracketed` rather than expanded with its tail left as text (PREPARE-10a1) — `scripts/deep-links.sh` (`run_resolution`), `tests/deep-links.test.sh`. The token reaches the matcher through the environment rather than an escape-processing `awk -v` assignment, so one carrying a backslash matches byte for byte instead of reporting as an untouched line (PREPARE-10) — `scripts/deep-links.sh` (`resolve`), `tests/deep-links.test.sh`. The review's baseline is always a readable path, an empty file where no CR holds a description, since the review wrapper takes a pair of paths and an empty value is a usage error it never opens past (PREPARE-13a) — `scripts/prepare-review.sh` (`current_desc_path`), `tests/prepare-review.test.sh`. Reports the branch's pipeline once the description lands (PREPARE-16), and names the source branch that won't be deleted on merge, offering the forge's remediation (PREPARE-17) — `skills/prepare-review/SKILL.md`, `scripts/{prepare-review,deep-links,pipeline-after-push}.sh`, `tests/prepare-review.test.sh`. The CR is labelled from the project's own set and given a milestone where one of its open ones fits, added to whatever it already carries (PREPARE-18) — `skills/prepare-review/SKILL.md` Step 4 ("Label it and set the milestone"), `guides/forge-cookbook.md` "Labels and milestones". An issue the CR resolves is referenced with the forge's closing keyword, so the merge closes it (PREPARE-19) — `templates/cr-description.md` Context. The default branch with a clean tree and nothing ahead reports `NOTHING_TO_REVIEW=1` and exits 65, so a dead end is an event rather than a key a caller can summarize past (PREPARE-02a) — `scripts/prepare-review.sh`, `tests/prepare-review.test.sh`. A dirty-tree stop reports that changes are uncommitted and nothing more, rather than diagnosing how the tree got that way (PREPARE-06a) — `skills/prepare-review/SKILL.md` "Act on `STATE`". The branch-inferred lookup adopts only an open CR, so a reused branch name whose earlier CR merged or closed gets a fresh draft, and the one passed over is reported as `PRIOR_CR_IID`/`PRIOR_CR_STATE`; an explicit `--cr` still resolves whatever was named (PREPARE-03a) — `scripts/prepare-review.sh` (`resolve_cr`), `skills/prepare-review/SKILL.md` "A reused branch name", `tests/prepare-review.test.sh` **Gaps (2026-10-01):** PREPARE-10a1: a prose `anchor:` is matched against claimed placeholders by substring, so it can ship raw (`scripts/deep-links.sh` `stray_anchors`) |
| REVIEW-01..33 (+03a) | 34 | 33 Covered, 1 Partial | The own CR's description keeps a Review status table of each commit's rounds, its reviewers by bare login, and its latest result, keyed by patch-id so a rebase keeps them and an amend starts over (REVIEW-31) — `scripts/lib/review-status.sh`, `tests/review-status.test.sh`; a finished review round gives each commit in its range another round, on someone else's CR only where the section exists and the CR is out of draft (REVIEW-32) — `scripts/review-status.sh` (`record`), `skills/review/SKILL.md` Step 9; a self-review starts from the oldest unreviewed commit, and asks when every commit has a round, re-reviewing the whole CR by default (REVIEW-33) — `scripts/review-cr.sh` (`REVIEW_STATUS_*`), `skills/review/SKILL.md` Step 1, `tests/review-cr.test.sh`. A round on your own CR hands each kept item's reason to the commit review as its note, and the round's message names the fixes (REVIEW-30) — `skills/review/SKILL.md` Step 7. Each round's size is drawn as a bar under the CR's, in the round's table and in the offer of another round (REVIEW-27) — `scripts/review-round.sh` (`seed`, `sizes`), `skills/review/SKILL.md` Step 7, `tests/review-round.test.sh`. One judgment over the examination's candidates, with two severities, a risk score, and no quota (REVIEW-28) — `skills/review/SKILL.md` "Judge the candidates", `templates/review-qualities.md` Output; items the user dropped are remembered as rejected and settled for later rounds (REVIEW-29) — `scripts/review-round.sh` (`finish`, `ROUND_REJECTED`), `tests/review-round.test.sh`; one note per item, naming its other sites (REVIEW-20) — `scripts/review-round.sh` (`seed`). Reviewing a CR in rounds — resolve it by number/URL/branch and read the description before the diff (REVIEW-01..04), and refuse to start without revdiff, since the round is carried by preloaded notes (REVIEW-05) — `skills/review/SKILL.md` Steps 1-2, `scripts/review-cr.sh`, `tests/review-cr.test.sh`. What a review looks for, and the bar a finding clears, is a template the user edits, weighed one agent per listed quality, and an empty result ends the review in one line (REVIEW-15, 16, 23) — `templates/review-qualities.md`, `skills/review/SKILL.md` Step 3. Findings one change resolves are one item with an id, slug, severity, and status; every item's fix that can be written as code is drafted and each recorded as its own patch in a private-index snapshot (REVIEW-19) — `skills/review/SKILL.md` Step 4, `scripts/review-round.sh` (`start`, `record`, `revert`), `tests/review-round.test.sh`. A note per item at each site, anchors checked against the pass's own diff before revdiff opens, and the `(context).md` table beside them, in two passes: the drafts alone from the CR head, then the CR with the kept fixes from the merge base, a note far from every change in its pass going to the table (REVIEW-20) — `scripts/review-round.sh` (`seed --pass`, `finish`), `skills/review/SKILL.md` Steps 5-7, `tests/review-round.test.sh`. What the user left is read back into keep, change, drop, ask, and new, with edits made inside revdiff kept as theirs (REVIEW-07, 21) — `scripts/review-round.sh` (`read`), `skills/review/SKILL.md` Step 7. Someone else's CR is edited in a worktree at its head, and a kept fix becomes a suggestion when it is one run of lines, a thread otherwise, anchored to the line it maps to in the CR head (REVIEW-22) — `scripts/review-round.sh` (`start --worktree`, `suggest`, `map_line`). A self-review edits the checkout on the CR head, commits each round through `/anchor:commit`, offers another round over that commit with how much each round so far changed, and hands off by marking the CR ready (REVIEW-17, 18, 24) — `skills/review/SKILL.md` Step 7, `scripts/mark-ready.sh`. The round's table, state, and worktree go when it ends (REVIEW-25) — `scripts/review-round.sh` (`finish`). Threads already open on the CR are reported before a pass, routing the author to `/anchor:resolve-feedback` and checking someone else's against the head (REVIEW-26) — `scripts/review-cr.sh` (`OPEN_THREADS`, `OPEN_FEEDBACK_PATH`), `skills/review/SKILL.md` Step 1, `tests/review-cr.test.sh`. Rounds are numbered in a session ledger recording each one's items, the user's notes and their size, and the lines it changed as a percent of the CR, shown as a trend with each later round (REVIEW-27) — `scripts/review-round.sh` (`--ledger`, `finish`, `trend`), `tests/review-round.test.sh`. The post places each finding at the narrowest anchor, gates on the exact text, and refuses a head that moved (REVIEW-08..14) — `scripts/review-post.sh`, `tests/review-post.test.sh` **Gaps (2026-10-01):** REVIEW-12: GitLab posts one thread at a time where a draft-notes batch may exist (unverified, needs decision) |
| FEEDBACK-01..09 | 9 | 7 Covered, 2 Partial | Fetch, triage, act on threads, watch the fix commit's pipeline into the summary (FEEDBACK-09) — `skills/resolve-feedback/SKILL.md`, `scripts/pipeline-after-push.sh` **Gaps (2026-10-01):** FEEDBACK-01: no pagination, bots unfiltered, unthreaded comments always read as unresolved; FEEDBACK-07: no reply route for unthreaded feedback |
| MERGE-01..19 | 19 | 18 Covered, 1 Partial | An own CR's commits with no review round ask before the merge, offering `/anchor:review`, and the rest of the gates are still read (MERGE-19) — `scripts/merge-gates.sh` (`GATE_REVIEWS`, `UNREVIEWED`), `skills/merge/SKILL.md` Step 1, `tests/merge-gates.test.sh`. Gate checks (ready/mergeable/pipeline/approvals/threads), method choice, merge + cleanup — `skills/merge/SKILL.md`, `guides/forge-cookbook.md`. The CR, the checkout, every gate, and the resolved method come from one call, stopping at the first blocking gate; the merge (guarded on the head SHA), its read-back, `cr.merged`, and the local cleanup from another (MERGE-13, 18) — `scripts/{merge-gates,merge}.sh`, `tests/{merge-gates,merge}.test.sh`. The draft, open-thread, and merge confirmations are `AskUserQuestion` prompts (MERGE-04, 10, 12). The draft gate clears the flag through `scripts/mark-ready.sh` rather than the CLI directly, so the transition is announced once wherever it is reached (EVENTS-12). The target branch's pipeline is watched on the landed SHA once the cleanup is done and reported through the shared template (MERGE-16) — `skills/merge/SKILL.md` Step 5, `scripts/pipeline-after-push.sh`, `guides/configuring.md` "Watching the pipeline a commit triggers". The gates report as one table and the method reaches the user as the confirmation prompt rather than prose ahead of it (MERGE-17) — `skills/merge/SKILL.md` Steps 1/2/6, `guides/execute-quietly.md` **Gaps (2026-10-01):** MERGE-10: GitLab bot threads count as human (`scripts/merge-gates.sh`) |
| RELEASE-01..19 (+03a, 03b, 03c, 04a) | 23 | 19 Covered, 4 Partial | Release-model detection, version recommendation, notes + review, per-model publish — `skills/release/SKILL.md`, `scripts/release-recon.sh`, `guides/release-models.md`, `guides/forge-cookbook.md`. A release workflow triggered only by `workflow_dispatch` reads as CI-owning the bump, gated on a second signal so the manual-run hatch that most workflows carry cannot name a docs deploy as the release workflow, and a `release`/tag trigger alongside it keeps its own model (RELEASE-03a) — `scripts/release-recon.sh` (`workflow_trigger`, `dispatch_publishes`, `detect_ci_model`), `tests/release-recon.test.sh`. The workflow's declared inputs and the one carrying the level are reported so the dispatch passes it by the workflow's own name (RELEASE-03b) — `scripts/release-recon.sh` (`dispatch_inputs`, `bump_input_of`, `RELEASE_DISPATCH_INPUTS`, `RELEASE_DISPATCH_BUMP_INPUT`). A repo that documents its publish path outranks the inference, and one that documents nothing behaves as before (RELEASE-03c) — `scripts/release-recon.sh` (`RELEASE_PUBLISH_DOCS`), `skills/release/SKILL.md` "The repo outranks the inference", `guides/release-models.md`. On that model the notes are committed into the accruing changelog section before the dispatch, so they are reviewed in the commit rather than as a release body, and the dispatch keeps its own confirmation (RELEASE-04a) — `skills/release/SKILL.md` Step 5, `scripts/release-recon.sh` (`RELEASE_NOTES_BASELINE`) **Gaps (2026-10-01):** RELEASE-03c: the publish statement is read only from `AGENTS.md` / `CONTRIBUTING.md` (needs decision); RELEASE-04a: no instruction when `## Unreleased` is absent; RELEASE-16: a shipyard regen is not detected (`find_regen_cmd`); RELEASE-19: merge Step 5 conditions on a `RELEASE_MODEL` no merge helper emits |
| ISSUES-01..14 | 14 | 13 Covered, 1 Partial | A batch planning a release carries the milestones it creates or edits as items beside the issues, published first, and a stored due date is read back against the approved one (ISSUES-13, 14) — `templates/batch-items.md` "Milestone", `skills/issue/SKILL.md` "Several issues at once", `guides/forge-cookbook.md` "Milestone create and edit". Author one issue — gather intent, guard duplicates, draft, file (`skills/issue/SKILL.md`). Filing also triages: labels come from the project's own set and a milestone from its open ones, ambiguity goes to the author, an existing issue is only added to, and both ride the body's approval (ISSUES-07..11) — `skills/issue/SKILL.md` Step 5 and Step 6 ("Yes (write)"), `guides/forge-cookbook.md` "Labels and milestones". The approval leads with a link to where the write lands, so the user reads the target before the draft (ISSUES-12) — `skills/issue/SKILL.md` Step 6 **Gaps (2026-10-01):** ISSUES-09: GitLab group milestones are not listed |
| BACKLOG-01..06 | 6 | All Covered | Survey what is already filed — scope from the query, rank due-soonest then most-recently-updated, recommend the top pick, write nothing (`skills/backlog/SKILL.md`). GitHub carries no per-issue due date, so the milestone's stands in for it (BACKLOG-04) — `skills/backlog/SKILL.md` Step 3, `guides/forge-cookbook.md` "Issue list" |
| CI-01..16 | 16 | 14 Covered, 2 Partial | Status/watch/job modes, commit-scoped resolution, per-workflow fold and the single-run opt-out; run/job breakdown tabulated with per-state emoji (CI-10..12) and watched once per commit after a push (CI-13..14) — `skills/pipeline/SKILL.md`, `skills/merge/SKILL.md` (CI-09), `templates/pipeline-report.md`, `scripts/{pipeline-status,pipeline-after-push}.sh`, `tests/pipeline-{status,after-push}.test.sh`. A newer watch on the same work stops the older one and says so (CI-15) — `guides/watching-a-pipeline.md`, linked from every skill that watches; an abbreviated `--sha` is resolved to the full commit, and one naming no commit fails naming it (CI-16) — `scripts/pipeline-status.sh`, `tests/pipeline-status.test.sh` **Gaps (2026-10-01):** CI-03: no command for watching the pushed tip; CI-10: GitLab reports only the newest pipeline per sha (needs decision) |
| DIFF-01..46 (+13a, 20a, 25a, 25b, 25c) | 50 | 46 Covered, 4 Partial | An edit made with revdiff's `e` in a `--files` review is written over the draft and returned as `editedFields`, an Accept of it coming back as `changes-requested` (DIFF-45), and a review carrying a draft offers a Verdict choice that relaunches it in the editor with the other notes in the buffer (DIFF-46) — `scripts/review/tools/revdiff.sh` (`diff_tool_edited`, `revdiff_relaunch_editor`), `scripts/review/modes/diff.sh` (`diff_relaunch`), `scripts/lib/verdict.sh`, `tests/review-diff.test.sh`. An `edit` review in Helix or Vim binds `ZZ` (approve), `ZX` (exit 2, reject), and `ZD` (save, exit 3, into `diff`), Helix through a workspace `.helix/config.toml` merged over the user's own and Vim through buffer-local maps; a buffer saved empty is `rejected` and an unsaved quit `undecided` (DIFF-44, DIFF-14, DIFF-39) — `scripts/review/modes/edit.sh` (`editor_open_args`, `editor_chords`, `editor_context`, `emit_review`), `tests/review-edit.test.sh`. A revdiff review's context file, and a batch's or round's table, carries a Verdict section: a note on Accept is `approved`, on Reject `rejected`, notes elsewhere `changes-requested`, a lone note saying only a verdict word (`lgtm`, `stop`, …) anywhere but on a preloaded note chooses as the line would (in a batch or round, only on the shared table off its rows, items' answers not counting against it), and no note of the reviewer's (a preloaded note returned as seeded is none) or both choices `no-verdict` `undecided`; the choosing note stays out of `REVIEW_RETURNED`, and `Q` is unbound for the review from the bindings `--dump-keys` reports (DIFF-42) — `scripts/lib/verdict.sh`, `scripts/review/tools/revdiff.sh` (`revdiff_unbind_discard`, `diff_tool_comments`, `diff_tool_shared_note`, `diff_tool_verdict`), `scripts/review/modes/diff.sh` (the preloaded filter, the lone verdict word, `undecided`), `scripts/{batch-edit,review-round}.sh`, `tests/review-diff.test.sh`. A `--files` review runs in a scratch repo with the left side committed and the right side over it, named for the object's reference where `--name` passes one (`CR_REFERENCE` from `scripts/prepare-review.sh`, the issue and release launch blocks), so it carries the context file, keys, and Verdict section, and the repo is removed when it closes (DIFF-43) — `scripts/review/tools/revdiff.sh` (`revdiff_files_scratch`, `diff_tool_cleanup`), `tests/review-diff.test.sh`, `tests/review-edit.test.sh`. The agent's notes on its own changes preload where the tool shows notes and are left out where it can't, the probe saying which (`REVIEW_PRELOADS`), with the context file kept and a note returned as seeded or deleted read as read (DIFF-41) — `scripts/review-diff.sh` (`--explain`, `tool_preloads`), `scripts/review/modes/diff.sh` (`diff_tool_file`, the seeded filter), `scripts/review/tools/revdiff.sh` (`revdiff_context_path`), `tests/review-diff.test.sh`. An `edit` review quit with status 2 reopens in `diff` mode on the draft as saved, returning that mode's verdict with any earlier edit in `editedFields`, and the buffer offers the switch only where a viewer is named (DIFF-39) — `scripts/review/modes/edit.sh` (`editor_annotate`, `editor_viewer`), `tests/review-edit.test.sh`. A `diff` review's `(context).md` puts the size under the title, then a solid box naming the keys the viewer maps, read from `revdiff --dump-keys`, then the Verdict section, the same box heading a review round's and a batch's table, and a note left on the file comes back with its line and the text it sat on (DIFF-40) — `scripts/lib/hints.sh` (`anchor_revdiff_hints`, `anchor_revdiff_box`), `scripts/review/tools/revdiff.sh` (`diff_tool_before`, `diff_tool_comments`), `scripts/{batch-edit,review-round}.sh`, `scripts/lib/callout.sh` (`anchor_box`), `tests/{review-diff,batch-edit,review-round}.test.sh`. A review's size is drawn as bars, and a reply review stacks each pass on one scale, newest first, down to the change the first review saw, the earlier passes carried from one review state to the next (DIFF-38) — `scripts/lib/size-stack.sh` (the width set by the largest pass, `tests/size-stack.test.sh`), `scripts/review-diff.sh` (`sizes.tsv`, `review_state_save` `earlier`), `scripts/review/tools/revdiff.sh` (`diff_tool_before`), `tests/review-reply.test.sh`. Tool-agnostic review contract — dispatcher `scripts/review-diff.sh` + adapters `scripts/review/modes/{edit,diff}.sh` + `scripts/review/tools/`; consumers read the normalized verdict, and treat an unparseable or absent one as no-verdict (DIFF-12) — `skills/{commit,prepare-review,issue,release,review}/SKILL.md` verdict sections. `edit` mode edits the artifact rather than commenting on it, reads the save as the verdict — a buffer left unsaved or saved empty aborts, and a save read from the buffer rather than from how the editor left survives the terminal going away afterwards — refuses a review with no artifact, and discounts a no-op `GIT_EDITOR` — continuing past git's own chain to git's compiled default where a terminal can be hosted and a blocking editor on `PATH` where none can, read independent of the ambient terminal and of the no-op values already discounted, so an agent harness holding no configured editor resolves the one a plain `git commit` would open and renders it in the pane anchor labels rather than a window behind the terminal (DIFF-13..16) — `scripts/review/modes/edit.sh` (`emit_review`), `scripts/lib/review-editor.sh` (`anchor_editor_resolve`, `anchor_editor_usable`); the buffer takes the artifact's own extension, so a markdown draft opens with the editor's markdown mode and preview available rather than as plain text (DIFF-13) — `scripts/review/modes/edit.sh` (`editor_buffer_ext`), `tests/review-edit.test.sh`; the buffer is named for the reference the caller passes (`--name`), else `<repo>@<branch>.<artifact>`, in a directory of its own, helix starts in that directory so its status line shows the name, and the `opened by` / `next` rows lead the details below the scissors (DIFF-13a, DIFF-34) — `scripts/review/modes/edit.sh` (`editor_buffer_name`, `editor_open_args`), `scripts/lib/tmpfile.sh` (`anchor_tmpdir`), `tests/review-edit.test.sh`; an editor that saved nothing is named rather than numbered — `unsaved`, `pane-closed`, `no-pane`, `no-host` on `raw.exitCode`, the first two carrying the remedy and treated as re-openable rather than as a rung of the ladder; and where the editor is one anchor knows that returned without its wait flag, the report names that editor and that flag rather than reporting a reviewer who declined to save (DIFF-14) — `scripts/review/modes/edit.sh` (`emit_review`'s cause map, `editor_rc_no_host`), `scripts/lib/editor-flags.sh` (`anchor_editor_wait_flag`, `anchor_editor_blocking`), `scripts/lib/review-host.sh` (`anchor_host_rc_no_result`, `anchor_host_rc_no_pane`), `guides/review-fallback.md` ("Don't retry into the same wall"), `tests/review-edit.test.sh`; the one skill whose subject is always a changeset catches that refusal at the probe rather than launching into it — `skills/review/SKILL.md` Step 3; `--probe` reports the resolved mode and the tool that would run it without launching, plus whether an editor review would reach an editor at all (DIFF-17) — `scripts/review-diff.sh` (`resolve_tool`), `scripts/lib/review-editor.sh` (`anchor_editor_host`, `anchor_editor_available`), `tests/review-edit.test.sh`; availability takes the program and the host together in `diff` as in `edit`, so an installed viewer with no terminal to render it in reports unavailable rather than sending the caller to launch into `no-host` — `scripts/review-diff.sh` (`mode_available`), `tests/review-edit.test.sh`. Resolution runs on two axes: a configured mode is kept so its own report names the missing piece, a subject-picked one gives way only to a mode openable in full — program and host together, so with nowhere to open either the subject's mode is kept and its report names the editor rather than trading it for a viewer — and on the tool axis nothing substitutes, so a viewer the user named is the viewer reported whether or not it is installed (DIFF-11) — `scripts/review-diff.sh` (`usable_mode`, `diff_mode_openable`, `resolved_mode_source`), `tests/review-{diff,edit}.test.sh`. git's difftool is a `diff` tool whose verdict is read from the working tree rather than from the tool: every reviewed file is snapshotted before it opens, each one the reviewer changed comes back carrying the diff of what they wrote, edits are `changes-requested` and an untouched tree is `approved`, and the tool's own exit status is not consulted since `git difftool` drops it (DIFF-18) — `scripts/review/tools/difftool.sh`, `scripts/lib/review-difftool.sh`, `tests/review-difftool.test.sh`. Sorting those edits into fixes to keep and questions to answer-and-remove is the model's, and the removal is verified before the re-review (UX-08) — `guides/reviewer-edits.md`, the `changes-requested` bullets of all five review-consuming skills. An ungraded review takes a fallback ladder rather than a "you saw it, approve?" question — the draft's path, the editor rung where DIFF-17 says it is reachable, and a chat read of the artifact or a file-by-file changeset walk as the floor (DIFF-20) — `guides/review-fallback.md`, the fallback sections of all five review-consuming skills. A git-range review takes caller-supplied header overrides, which is what keeps another author's CR from being labelled with the reviewer's own last commit (DIFF-19) — `scripts/review-diff.sh` (git-range `--title` / `--detail`), `tests/review-cr.test.sh`. An empty resolved range reports `no-verdict` with `raw.exitCode` `empty-range` and launches nothing, since a viewer quit on an empty diff is indistinguishable from an approved review (DIFF-21) — `scripts/review-diff.sh` (empty-range gate), `tests/review-diff.test.sh`. `--local` stages the caller's named paths so a new file reaches the diff, and stops on a path with nothing to stage, rather than sweeping in a co-resident session's work (DIFF-22) — `scripts/review-diff.sh` (`--path`), `scripts/lib/stage-paths.sh` (`anchor_stage_paths`), `tests/review-diff.test.sh`. A `--staged-path` review shows the index against HEAD — revdiff runs with `--staged` — and a tool whose verdict is read from edits to the working tree returns `no-verdict` with `raw.exitCode` `staged-unsupported` (DIFF-33) — `scripts/review-diff.sh` (`diff_staged`), `scripts/review/modes/diff.sh` (`diff_tool_reports_via_tree` gate, which also returns `range-unsupported` for a commit range), `scripts/review/tools/revdiff.sh`, `scripts/review/modes/edit.sh`, `tests/review-diff.test.sh`. A re-opened review compares against the draft the reviewer graded rather than the artifact the forge holds, so the second pass shows what the feedback changed (DIFF-23) — the `changes-requested` bullets of `skills/{prepare-review,issue,release}/SKILL.md`. The tool probe runs under the same `--skill` the launch uses, and the consumer names the tool it opens, so a review waiting in a window behind the terminal is not read as a step that never ran (DIFF-24) — the probe blocks of `skills/{prepare-review,issue,release}/SKILL.md`, which name the tool on a defaulted choice as well as a substituted one now that the probe reports which it was. **Partial**: `skills/commit/SKILL.md` does not probe at all, so the tool it opens goes unnamed. A review needing a terminal opens where the calling session can put one — a tmux popup, an iTerm2 split of that session, a floating overlay on the calling agterm session, addressed by `AGTERM_SESSION_ID` over a live control socket — and the borrowed screen is returned when it closes, so the review cannot rest behind the window the user is watching; one dispatcher answers both the probe and the launch, so they cannot disagree (DIFF-25) — `scripts/lib/review-host.sh` (`anchor_host_available`, `anchor_host_run`), `scripts/lib/review-editor.sh` (`anchor_editor_host`), `tests/review-edit.test.sh`. That host is resolved from one ranked set independent of the mode, so `edit` and `diff` reach equally far; a host serving one mode alone says so rather than getting a selector of its own — the `gui` window answers only `edit` — and the set holds no host the harness could never select, a plugin's scripts being invoked with no controlling terminal (DIFF-25a) — `scripts/lib/review-host.sh` (`anchor_review_hosts`, `anchor_review_host_select`), `scripts/review/hosts/{tmux,gui,iterm2,agterm}.sh` (the `gui` window's own availability reading `scripts/lib/editor-flags.sh`), `tests/review-edit.test.sh`, `tests/review-host.test.sh`. A program the user names in `ANCHOR_HOST_RUNNER` takes the place of the shipped set in both modes, and the no-host report in each mode links to the guide section documenting the hosts and it (DIFF-25b) — `scripts/lib/review-host.sh` (`anchor_review_host_select`, `anchor_host_run`, `anchor_review_hosts_doc`), `scripts/review/modes/edit.sh` (`editor_launch`), `scripts/review/modes/diff.sh` (the `no-host` gate), `guides/configuring.md` "Where a review opens", `tests/review-edit.test.sh`. The agterm overlay opens on the calling session without selecting it, marks that session's sidebar row `blocked` from the caller's pane while the review is open, and clears the mark itself when it closes, a refused write leaving the review to run (DIFF-25c) — `scripts/review/hosts/agterm.sh` (`agterm_status`, `review_host_run`), `tests/review-host.test.sh`. The split carries the directory and the environment the command was resolved against, since a split is not run through a login shell and starts on the terminal's own: a second lookup over there fails on a tool that is installed, and refs resolved against the repo under review draw a different repo's diff from wherever the pane stands (DIFF-26) — `scripts/lib/review-host.sh` (`anchor_host_launch_script`), `tests/review-host.test.sh`. The diff viewer is driven directly rather than through the revdiff plugin's launcher, and an absent viewer, unhostable session, or pane closed before it reported reports `no-verdict` with `raw.exitCode` `absent`, `no-host`, `no-pane`, or `pane-closed` (DIFF-27, DIFF-14) — `scripts/review/modes/diff.sh` (`emit_review`), `scripts/review/tools/revdiff.sh`, `tests/review-diff.test.sh`. An open review is waited on for as long as the reviewer takes, ended early only by the host closing without a result, and never by elapsed time; the result is read once more after the host is seen gone, since quitting the tool writes the status and closes the pane in the same breath and the liveness probe answers for a moment already past (DIFF-28) — `scripts/lib/review-host.sh` (`anchor_host_await`, `anchor_host_read_rc`, `anchor_host_probe_seconds`), `scripts/review/hosts/iterm2.sh` (`iterm2_pane_alive`), `tests/review-host.test.sh`. The split carries the calling session's rendered tab label behind a 👀, attempted rather than required, so the tab the user navigates by keeps its label while the focused review pane holds it and says a review is waiting there (DIFF-29) — `scripts/review/hosts/iterm2.sh` (`review_host_run`'s launch AppleScript). The pane is selected once it is open, since a scripted split is created without being selected and leaves the reviewer typing into the session that is waiting on them (DIFF-30) — `scripts/review/hosts/iterm2.sh` (`select newSession` in the launch AppleScript). Comments an `approved` verdict carries are reported without gating the operation, and one asking for follow-up work to be filed rather than fixed now is carried out (DIFF-31) — the approved-verdict handling of `skills/{commit,prepare-review,issue,release}/SKILL.md`. Feedback given in chat while a review is open halts the flow with the review left in place, and the review that closes is followed by a second one over both sets of feedback, whatever it returned (DIFF-32) — `guides/running-a-review.md`, linked from the launch step of `skills/{commit,prepare-review,issue,release,review}/SKILL.md`. A review opened under `--skill` leads its header with `opened by` and `next` rows naming that skill and what approving hands it, ahead of the caller's own rows, in both modes (DIFF-34) — `scripts/review-diff.sh` (`review_next_step`), `scripts/review/modes/diff.sh` (the plain-text header revdiff shows), `tests/review-diff.test.sh` An ungraded review opens and closes its reply with an error banner, and publishes only through an `Unreviewed` choice that names the remote action, never on a bare "ok" (DIFF-20a) — `guides/review-fallback.md` ("Mark the reply as a failed review"), `guides/running-a-review.md`, `skills/{commit,review}/SKILL.md`. Notes to preload and untracked files reach a tool that can carry them, the reviewer's returned set lands in `REVIEW_RETURNED`, a tool that can't carry them returns `no-verdict` (`annotations-unsupported`, `untracked-unsupported`), and a note on an unchanged line comes back with its file and line (DIFF-35) — `scripts/review-diff.sh` (`--annotations`, `--untracked`), `scripts/review/modes/diff.sh`, `scripts/review/tools/revdiff.sh` (`diff_tool_comments`), `tests/review-diff.test.sh`. A `changes-requested` `--local` review in a tool that preloads notes keeps the changeset as it closed and its comments (`REVIEW_STATE`); the re-review opens on what changed after it, with a reply to every comment on its line under *You asked:* and a table of them heading `(context).md`, seeding refuses a comment left unanswered, and a reply returned as seeded or deleted is read rather than taken as feedback (DIFF-37) — `scripts/review-reply.sh`, `scripts/review-diff.sh` (`--reply`, `review_state_save`), `scripts/lib/stage-paths.sh` (`anchor_review_snapshot`), `scripts/review/modes/diff.sh` (the reply filter), `scripts/review/tools/revdiff.sh` (`diff_tool_before`, `diff_tool_comments`), `guides/running-a-review.md` ("Re-reviewing a changeset is a reply"), `skills/commit/SKILL.md`, `tests/review-reply.test.sh`. **Gaps (2026-10-01):** DIFF-04: the verdict table lacks the exit-10-with-no-comments row and a difftool column; DIFF-09: `raw` drops the comment header (`scripts/review/tools/revdiff.sh` `diff_tool_comments`); DIFF-20: still `--tool editor`; DIFF-24: still Partial |
| CONFIG-01..21 (+15a, 15b) | 23 | 14 Covered, 9 Partial | `anchor.hints=false` drops the tool's keys from every review context and keeps what quitting does, `anchor.diff.hints` / `anchor.edit.hints` overriding it per mode (CONFIG-21) — `scripts/lib/hints.sh` (`anchor_hints_on`), `scripts/review/tools/revdiff.sh`, `scripts/{batch-edit,review-round}.sh`, `scripts/review/modes/edit.sh` (`editor_context`), `tests/{review-diff,review-edit,review-round}.test.sh`. `anchor.*` key handling, including the per-skill after-push watch gate (CONFIG-06), the review **mode**, which has no key at all — the subject settles it, `edit` where the review is one file with no prior version to compare against and `diff` everywhere else, a git range included since it names a base by construction — and which is still settled against what can actually open rather than assumed present (CONFIG-15 — `scripts/review-diff.sh` (`subject_default_mode`, `resolve_mode`, `usable_mode`), `guides/configuring.md` "A mode per subject", `tests/review-{edit,diff}.test.sh`). What *is* configurable is the tool, one symmetric key per mode: `anchor.edit.tool` over git's chain, `anchor.diff.tool` over git's own `diff.tool` with no viewer assumed past either — an unset pair reports `no-tool` naming the keys rather than selecting revdiff on the user's behalf, since a tool nobody chose returns a verdict recorded as theirs — the superseded single key reported as doing nothing rather than silently obeyed or ignored (CONFIG-15a — `scripts/review-diff.sh` (`resolve_tool`, `report_superseded_key`), `scripts/review/modes/diff.sh` (the `no-tool` gate), `scripts/lib/review-editor.sh` (`anchor_editor_configured`), `guides/configuring.md` "`anchor.diff.tool`", "Where a review opens", `tests/review-edit.test.sh`). The probe is answered from the same subject the launch will carry, and the consumers pass it, so a pre-launch question and the launch cannot name different tools (CONFIG-15b — `scripts/review-diff.sh` (`subject_flag`, `subject_left`), the probe blocks of `skills/{prepare-review,issue,release}/SKILL.md`, `tests/review-edit.test.sh`), and a verbosity dial per artifact — CR (CONFIG-07..10), commit message body (CONFIG-11), issue body (CONFIG-12), release notes (CONFIG-13) — each abbreviating sections rather than removing them, with the cross-artifact invariants, the clamp, and the audience-widens-as-the-default-descends ordering in CONFIG-14 — `guides/configuring.md` (Defaults table), `guides/cr-verbosity.md`, `templates/{cr-description,commit-message,issue-description}.md` ("At lower verbosity"), `scripts/pipeline-after-push.sh` (`config_bool`), commit/prepare-review/issue/release config steps, `tests/config-defaults.test.sh` (the documented defaults agree across SPEC, guide, skills, templates). Keys are named `anchor.<qualifier>.<setting>` throughout — the qualifier saying what a setting applies to, the setting saying what is set, an unqualified `anchor.<setting>` the base — with most-specific-qualifier precedence — forge, then artifact type, then the base — resolved per setting (CONFIG-16, 17) — `scripts/lib/anchor-config.sh`, `guides/configuring.md` "How a key is named", `tests/anchor-config.test.sh`. The qualifier precedes the setting on every key and the reverse is not accepted, since `git config` reads the last dot-separated segment as the key name — which is what keeps a dotted qualifier, a specific host should one be wanted, addable without moving the keys that exist (CONFIG-18) — read off how git stores the key in `tests/anchor-config.test.sh` rather than asserted. A key set under a superseded camelCase name is reported with the key that replaced it and is not acted on; nothing is carried, because `mrRules` / `prRules` overrode the CR rules alone where `anchor.gitlab.*` / `anchor.github.*` qualify every artifact bound for that forge, so a mechanical carry would widen the setting (CONFIG-19) — `scripts/lib/anchor-config.sh` (`anchor_config_renames`, `anchor_config_warnings`), `guides/configuring.md` "Renamed keys". git holds a subsection case-sensitively where it folds the section and the setting, so a qualifier differing from a known one only by case is inert and is reported with the spelling that would be read (CONFIG-20) — `scripts/lib/anchor-config.sh` (`anchor_config_warnings`) **Gaps (2026-10-01):** CONFIG-01, CONFIG-20: `commit` and `release` match the whole key case-insensitively; CONFIG-03: `commit` skips the `Refs:` trailer on a trivial commit (needs decision); CONFIG-15, 15a, 15b: as in Open; CONFIG-16: nothing reads the base `anchor.<setting>` (needs decision); CONFIG-17: forge keys apply to CRs only (needs decision); CONFIG-19: `issue` and `release` do not report superseded keys |
| FORGE-01..12 | 12 | 11 Covered, 1 Partial | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md`; template resolution across the forge's own inheritance with a deterministic per-level pick and the `anchor.cr.templateRepo` backstop (FORGE-06..09) — `scripts/prepare-review.sh`, `tests/prepare-review.test.sh`. A composed draft carries no placeholder the template left for the author, found by matching the template's own placeholders against the draft so text the drafter wrote can't trip it (FORGE-10) — `scripts/template-check.sh`, `skills/prepare-review/SKILL.md` output checklist, `tests/template-check.test.sh`; every checkbox is listed for the drafter to settle against evidence, ticked, unticked, or dropped and named when nothing settles it, with the state found in the template or the existing description never carried over (FORGE-11, 12) — `templates/cr-description.md` "Honoring a project's forge template", `skills/prepare-review/SKILL.md` "Honor an existing forge template" **Gaps (2026-10-01):** FORGE-01: issue templates are read from the local checkout only, and GitLab's `issues_template` default is unread |
| EVENTS-01..17 | 17 | 15 Covered, 2 Partial | Announcements to sibling plugins — one line per fact the plugin caused, the `codes.bridgeai.anchor/` prefix taken from `name:` so a producer cannot typo its own and cannot announce on a sibling's behalf (EVENTS-01, 02) — `scripts/announce.sh`, `plugin.yml` (`events.publishes`), `tests/announce.test.sh`. The body is built by `jq` rather than interpolated, which is what keeps a value carrying a quote, a backslash, or a newline on one line, and the publisher exits 0 on every path including a missing `jq`, so an announcement cannot turn an operation that succeeded into a tool call that failed (EVENTS-03, 04) — `tests/announce.test.sh` (the round-trip, newline, and no-jq cases). A declared key and the source that emits it have to name each other, which is what keeps a manifest that drives documentation from going stale silently (EVENTS-05) — `tests/announce.test.sh` (the drift trap). A fact a script causes announces from that script, after the operation lands, so a run whose skill stops early still announced the push or the CR (EVENTS-06, 07) — `scripts/prepare-review.sh`, `scripts/commit.sh`, `tests/commit.test.sh`; and `cr.created`/`cr.updated` are exclusive, decided by `CR_CREATED` (EVENTS-08) — `skills/prepare-review/SKILL.md` ("Announce what this run did"). A commit announces after the push, and its address names the project as well as the sha, built from `origin` across the remote shapes a clone can carry and with credentials in that remote dropped rather than announced (EVENTS-09, 10) — `scripts/lib/forge-url.sh`, `tests/forge-url.test.sh`. The draft flag is read at the moment it is cleared and `cr.ready` fires only where it moved, from the one helper both the self-review handoff and the merge gate call (EVENTS-11, 12) — `scripts/mark-ready.sh`, `skills/review/SKILL.md` Step 5, `skills/merge/SKILL.md` gate 1a, `tests/mark-ready.test.sh`. `cr.merged` carries the forge's own merge time and landed sha, read back rather than assembled from what the run knows, and covers the merges anchor performed rather than one the forge completes on its own afterwards (EVENTS-13, 14) — `scripts/merge.sh`, `tests/merge.test.sh`. `release.created` waits on the forge reporting the release and reads its address and tag back from there, since on the CI-owned models the workflow derives the version; a model that publishes no forge release announces nothing (EVENTS-15, 16) — `skills/release/SKILL.md` Step 6 ("Announce it"). `issue.created` fires on a create only (EVENTS-17) — `skills/issue/SKILL.md` "Yes (write)" **Gaps (2026-10-01):** EVENTS-15: the release read-back defaults to the latest release, so a red run can announce the previous one; EVENTS-16: the no-release rule lists models rather than checking for the tag's release |
| RULE-01..05 (+04a) | 6 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md`; RULE-04 routes CR creation through `prepare-review`. The CR-creation URL a push prints is ruled out alongside the bare `create` it stands in for, since it reaches the same web form with the drafting moved onto the user (RULE-04a) — `rules/use-forge-clis.md`, `skills/commit/SKILL.md` Step 6 `scripts/commit.sh` reads the squash gate again where an amend runs and refuses with exit 69 when it closed (RULE-05) |
| UX-01..05 (+01a, 02a, 02b, 06, 06a, 07, 08, 09, 10, 11, 12) | 16 | 14 Covered, 2 Partial | Reasoning about a change the agent made reaches the user as notes on its lines, and the permanent record keeps only what stays true (UX-12) — `docs/README.md` (tenet), `guides/review-notes.md`, `skills/{commit,review}/SKILL.md`. The probe reports the host a review opens in, and the manifest opens with where that is (UX-11) — `scripts/review-diff.sh` (`REVIEW_HOST`), `guides/running-a-review.md`, `tests/review-edit.test.sh`. A reply in a file with no change since the last review is answered in `(context).md` with the lines it concerns quoted, and the file stays out of the review (UX-10) — `scripts/review-reply.sh` (`changed_file`, `excerpt`), `guides/running-a-review.md`, `tests/review-reply.test.sh`. Narration, orchestration, decision prompts, artifact visibility, recon-supplied values — cross-cutting, each `skills/*/SKILL.md`, `guides/execute-quietly.md`. A skill that creates its own task list names each task by the work it tracks, with no step number, since the list covers only some of the skill's numbered steps (UX-02a) — the task-tracking blocks of `skills/{merge,release,resolve-feedback,review}/SKILL.md`. A skill reads the tool listing before it calls a task tool, so a session without the task tools loads the skill with no tool error (UX-02b) — `guides/task-tracking.md`, the task-tracking blocks of `skills/{commit,merge,pipeline,release,resolve-feedback,review}/SKILL.md`, `tests/task-tracking.test.sh`. A step that did not complete is reported in terms the user can see rather than in the vocabulary of anchor's own guidance, so a reply names the editor that closed rather than the position the guidance puts it in (UX-01a) — `guides/review-fallback.md` ("Say what happened, not where you are in this guide"). A review launch carries a manifest of what is under review — the CR in its forge's short form (the repo and branch without one), the size, the tool, and what approving sets off, the commit's CR read by the squash gate (`CR_REF`, `CR_URL`) — since the tool draws one file at a time and never shows the set (UX-07) — `guides/execute-quietly.md` ("show what is going under review"), the launch blocks of `skills/{commit,prepare-review,issue,release,review}/SKILL.md`, `scripts/squash-check.sh`, `tests/squash-check.test.sh`. A mode or a tool anchor settled on rather than the user gets the key that would choose it named in the same message, for that half only, so the hint sits next to what the user didn't pick and retires once they pick one (UX-07) — `scripts/review-diff.sh` (`REVIEW_MODE_SOURCE`, `REVIEW_TOOL_SOURCE`), `scripts/lib/review-editor.sh` (`anchor_editor_source`), `guides/execute-quietly.md` ("when anchor picked the tool"), the probe blocks of `skills/{prepare-review,issue,release}/SKILL.md`, `tests/review-edit.test.sh`. Prescribed commands use a shape and a path the caller can grant, paired with the allow rule that covers them and scoped to a stated set of shells and platforms, while anchor's own scripts stay free to honor `$TMPDIR` (UX-06, 06a) — `guides/temp-paths.md`, `rules/use-forge-clis.md`, `guides/forge-cookbook.md`, `skills/{commit,issue,resolve-feedback}/SKILL.md`, `scripts/lib/tmpfile.sh`, `tests/tmp-path-guidance.test.sh` (ubuntu/macOS/Windows matrix) A seeded note sits on the line it concerns, the changed line or the line the reviewer asked on, and goes on a whole file only when it concerns that file or the issue, CR, or thread a batch item stands for, and into `(context).md` only when it concerns the changeset as a whole (UX-09) — `guides/running-a-review.md` ("Put each note where the reader is already looking"), `skills/review/SKILL.md` Step 5, `guides/batch-review.md`. **Gaps (2026-10-01):** UX-02: as in Open; UX-07: the probe-table row keys the hint on `REVIEW_MODE_SOURCE=subject` (`guides/running-a-review.md`) |
| CONFIRM-01..17 | 17 | 16 Covered, 1 Partial | The Review status section is written without an approval gate (CONFIRM-17) — `scripts/review-status.sh`. A batch across repos names each item's repo below its kind, read from its url, and `start` refuses a path that leaves it out or names another (CONFIRM-16) — `scripts/batch-edit.sh` (`start`), `tests/batch-edit.test.sh`. A batch and a review round open their tables by saying who opened the review and why, what each verdict does, and that the table is the guide rather than an item; a round's also names the repo and links the CR (CONFIRM-15) — `scripts/review-round.sh` (`seed`), `scripts/batch-edit.sh` (`start`), `tests/{batch-edit,review-round}.test.sh`. A batch and a review round read their tables through one set of rules, so a deleted row drops and an edited or annotated row changes in both (CONFIRM-14) — `scripts/lib/item-review.sh` (`ANCHOR_ITEMS_JQ`), `scripts/{batch-edit,review-round}.sh` (`read`), `tests/{batch-edit,review-round}.test.sh`. Approval of the exact text before anything publishes under the user's name — commit message (`skills/commit/SKILL.md` Step 5), CR description (`skills/prepare-review/SKILL.md` Step 4), issue body (`skills/issue/SKILL.md`), thread replies (`skills/resolve-feedback/SKILL.md` 3c), release notes (`skills/release/SKILL.md`); CONFIRM-03 is the plan-is-not-prose distinction the reply gate rests on. A diff-mode review prints the drafted message verbatim with its manifest, and on the fallback walk, since revdiff shows it in a `(context).md` file the reviewer has to open and a difftool not at all (CONFIRM-07) — `guides/execute-quietly.md`, `skills/commit/SKILL.md` Step 5. revdiff shows the header as `(context).md` at the root of the tree, written beside the repo's files and listed in `info/exclude` so git never stages it, and a note on it comes back as a comment targeting the message; a batch or round shows its own table there, and notes on it stay on the table; a review holding that file alone opens with `REVDIFF_NO_TREE`, so revdiff's markdown outline of its headings never stands in for the tree (CONFIRM-08, DIFF-36) — `scripts/review/tools/revdiff.sh` (`diff_tool_before`, `diff_tool_command`, `diff_tool_comments`), `scripts/review-round.sh` (`seed`), `tests/review-diff.test.sh`, `tests/review-round.test.sh`. `resolve-feedback` commits each round of fixes through one commit review and `commit.sh --reviewed-index` (CONFIRM-09) — `skills/resolve-feedback/SKILL.md` 3b, `scripts/review-diff.sh` (`review_next_step`). Edits to two or more targets are approved as one batch in revdiff, one file per item with a `(context).md` table grouped by kind and review-only notes, each item's outcome read back by the script, and nothing published from a review that didn't complete (CONFIRM-10..13) — `scripts/batch-edit.sh`, `guides/batch-review.md`, `skills/issue/SKILL.md` "Several issues at once", `skills/resolve-feedback/SKILL.md` 3c, `tests/batch-edit.test.sh`. **Partial**: CONFIRM-06 — an approved `edit`-mode review returns the saved text only in `editedFields`, and `prepare-review` writes from the draft file (#148). |
| SANITIZE-01..11 | 11 | All Missing | Removing what should not reach a destination before the CONFIRM gate sees it. Motivated by [pwsh-gitlab#167](https://github.com/chris-peterson/pwsh-gitlab/pull/167), whose Validation section carried `gitlab.getty.cloud` into a public github.com PR description anchor drafted. Nothing implements these: detection wants `scripts/sanitize-check.sh` (deterministic, per SANITIZE-03), the replacement half wants a step in each drafting skill ahead of its approval gate, the `deny`/`allow` keys want the CONFIG-16 shape, and SANITIZE-11's second net wants a quality added to `templates/review-qualities.md` |

## Open / Needs Decision

- **CONFIRM-06 (Partial)** — an approved `edit`-mode review returns the reviewer's saved text in `REVIEW_OUTPUT.editedFields` and leaves the draft file as drafted, and `skills/prepare-review/SKILL.md` writes the CR from the draft file, so a reviewer's edit can be lost at the write. Tracked in #148.
- **DIFF-24 (Partial)** — the requirement holds in `skills/{prepare-review,issue,release}/SKILL.md`, which name the tool on a defaulted choice as well as a substituted one now that `REVIEW_TOOL_SOURCE` says which it was. `skills/commit/SKILL.md` skips the probe entirely, so the tool it opens still goes unnamed. Extending the rule to it, or narrowing DIFF-24 to the skills that draft a standalone document, is a decision pending.
- **CONFIG-15 / CONFIG-15a (Partial)** — the dispatcher is right and skill prompts describe a resolver that no longer exists. `skills/prepare-review/SKILL.md` tells the model a per-skill *mode* key is consulted, where `scripts/review-diff.sh` (`resolve_mode`) reads the mode off the subject alone; `skills/commit/SKILL.md` and `skills/issue/SKILL.md` name `revdiff` as the default viewer, where `resolve_tool` assumes no viewer past the configured keys. Both are stale prose against correct code.
- **UX-02 (Partial)** — six skills open with the orchestrated-task check; `prepare-review`, `issue`, and `backlog` carry none. `prepare-review` is the one that matters, since the release and merge flows reach it mid-orchestration.
- **DIFF-20 (Partial)** — the ungraded-review ladder's editor rung invokes `review-diff.sh … --tool editor`, which names a tool within a mode rather than the mode. The re-open case that reaches the rung carries a non-empty left side, so it resolves to `diff`, finds no such tool, and returns `no-verdict`. `--mode edit` is the invocation the requirement describes.
- **Needs decision (Partial)** — TARGET-05 (substring fallback or ask, given TARGET-10's reason for exact matching), REVIEW-12 (confirm GitLab's draft-notes batch on the target instances), RELEASE-03c (widen the files read, or name them in the spec), CI-10 (fold every GitLab pipeline per sha, or specify the newest), CONFIG-03 (`Refs:` on a trivial commit), CONFIG-16 (implement the base `anchor.<setting>` or narrow the spec), CONFIG-17 (forge keys for every artifact or CRs only; CONFIG-19's rationale depends on the answer).

## Audit history

### 2026-10-28 — Keep a revdiff edit, and relaunch a review in the editor (DIFF-45, DIFF-46)

STATUS.md updated: +2 IDs (DIFF-45, DIFF-46, Covered), 339 → 341.

A `--files` review in revdiff runs in a scratch repo, and an edit made there
with `e` was deleted with it. `scripts/review/tools/revdiff.sh`
(`diff_tool_edited`) writes it over the draft and returns it as `editedFields`,
and `scripts/review/modes/diff.sh` reads an Accept of an edited draft as
`changes-requested`. A review carrying a draft offers "Relaunch in <editor>" in
its Verdict section (`scripts/lib/verdict.sh`), which starts the review over in
`edit` mode with the other notes in the buffer (`diff_relaunch`)
(`tests/review-diff.test.sh`). Only the new IDs were read against the code in
this refresh.

### 2026-10-28 — Record each commit's review rounds on the CR (REVIEW-31..33, COMMIT-25, MERGE-19, PREPARE-20, CONFIRM-17)

STATUS.md updated: +7 IDs (REVIEW-31, REVIEW-32, REVIEW-33, COMMIT-25,
MERGE-19, PREPARE-20, CONFIRM-17, Covered), 332 → 339.

The round ledger lived in the session, so a review of one new commit on top of
others left nothing saying which of the others had never been reviewed. The
user's own CR now carries a Review status section (`scripts/lib/review-status.sh`)
that `scripts/review-status.sh record` updates after a finished self-review round
and after `/anchor:commit` pushes a reviewed commit. `scripts/review-cr.sh`
reports the unreviewed commits so a self-review starts from the oldest one,
`scripts/merge-gates.sh` asks before landing any, and `scripts/prepare-review.sh`
sets the section aside while the description is redrafted. A push of existing
commits (`/anchor:commit` push-existing) records nothing. Only the new IDs were
read against the code in this refresh.

### 2026-10-28 — Name a reviewed file for the object it edits (DIFF-13a, DIFF-43)

STATUS.md updated: no new IDs, 332 held; DIFF-13a and DIFF-43 amended.

A `--files` review in revdiff showed the draft's temp name
(`cr-desc-draft.a1B2c3.md`), so nothing on screen said which CR or issue was
being edited. `scripts/review-diff.sh --files` takes `--name <ref>`, which names
the file in revdiff and the `edit` buffer; `scripts/prepare-review.sh` reports
`CR_REFERENCE`, and the prepare-review, issue, and release launch blocks pass
it (`tests/review-diff.test.sh`, `tests/review-edit.test.sh`,
`tests/prepare-review.test.sh`). A difftool review still opens the temp paths.

### 2026-10-28 — Decide each item before reviewing the whole change (REVIEW-19, 20, 24)

STATUS.md updated: no new IDs, 332 held; REVIEW-19, REVIEW-20, REVIEW-24 amended.

A round opened one revdiff view from the merge base, so on a large CR each
item's note sat inside the CR's whole diff and a fix was hard to tell from the
change it commented on. The round now opens twice: an items pass from the CR
head holding only the drafts, then a whole pass from the merge base with the
kept fixes in it (`scripts/review-round.sh` `seed --pass`, `ROUND_FROM`).
Every item's fix is drafted so the items pass has a hunk to decide; a dropped
draft is reverted. A line note in a file the pass doesn't change goes to the
table rather than being refused, `read` folds a reviewer's own edit into the
recorded tree so the next pass seeds over it, and `finish` records both passes'
answers, a drop in the whole pass overriding a keep
(`tests/review-round.test.sh` "two passes"). Another round is recommended when
the round kept a critical fix. Only the changed IDs were read against the code
in this refresh.

### 2026-10-27 — Choose the verdict in the review (DIFF-42..44, CONFIRM-16)

STATUS.md updated: +4 IDs (DIFF-42, DIFF-43, DIFF-44, CONFIRM-16, Covered), 328 → 332;
DIFF-14 and DIFF-39 amended for edit mode's reject (exit 2) and switch (exit 3);
DIFF-40, CONFIG-21, CONFIRM-12, 13, 15 and the verdict table amended,
`rejected` added to the contract.

revdiff exits 0 for `q` with no notes and for `Q`, which discards them, and its
owner declined a distinct abort status (umputun/revdiff#412), so a quit can't
say whether the reviewer approved. The verdict is now a note on the context
file's Verdict section (`scripts/lib/verdict.sh`), read by
`scripts/review/tools/revdiff.sh`; a review that chose nothing is asked about,
and `Q` is unbound. A `--files` review leaves revdiff's compare mode, which
refuses `--only` and `--annotations`, for a scratch repo, so it gets the context
file too. A batch across repos names each item's repo in its path
(`scripts/batch-edit.sh`). Only these three and the amended IDs were read
against the code in this refresh.

### 2026-10-23 — Notes on the agent's own changes (UX-12, COMMIT-23, COMMIT-24, REVIEW-30, DIFF-41)

A commit's review carries the agent's notes on the hunks a reader would ask
about, and a review round hands its kept items' reasons to that review, so the
commit message and CR description keep only what stays true. A first commit is
reviewed against the empty tree. Only these five were read against the code in
this refresh.

### 2026-10-22 — Say how to work a review, and switch an edit to a diff (DIFF-38..40, REVIEW-27, CONFIG-21)

STATUS.md updated: +3 IDs (DIFF-39, DIFF-40, CONFIG-21, Covered), 320 → 323;
DIFF-38 and REVIEW-27 amended.

A size stack heads each row with a context line rather than an `@@` heading, and
a review with one size draws its counts with no label
(`scripts/lib/size-stack.sh`). A first review round draws the CR's size alone,
coloured, since its fixes are still proposals (`scripts/review-round.sh`
`seed`). What quitting does is boxed wherever a review states it: revdiff's
`(context).md`, a review round's and a batch's table, and an editor buffer
(`scripts/lib/callout.sh`). Each puts the keys the review tool maps in that box
(`scripts/lib/hints.sh`), and `anchor.hints` turns them off. An editor quit with
status 2 hands the draft to the viewer (`scripts/review/modes/edit.sh`
`editor_annotate`). Only DIFF-38..40, REVIEW-27 and CONFIG-21 were read against
the code in this refresh.

### 2026-10-22 — Colour only the pass under review in a size stack (DIFF-38, REVIEW-27)

STATUS.md updated: no new IDs, 320 held; DIFF-38 and REVIEW-27 amended.

Every row of a stack was coloured alike, so the pass under review didn't stand
out from the history under it. `anchor_size_stack current` keeps the first row's
`@@` heading and `+`/`-` bars and draws each later row as uncoloured context
lines with signed counts, each under its own heading line (`scripts/lib/size-stack.sh`).
A reply review's `(context).md` (`scripts/review/tools/revdiff.sh`) and a review
round's table (`scripts/review-round.sh` `seed`) pass it; the offer of another
round (`sizes`) has no current pass and stays coloured throughout. Only DIFF-38
and REVIEW-27 were read against the code in this refresh.

### 2026-10-22 — Draw every review's size as bars, newest pass first (DIFF-38, REVIEW-27)

STATUS.md updated: no new IDs, 320 held; DIFF-38 and REVIEW-27 amended.

A first review gave its size as numbers and a reply review as bars, so the two
didn't read alike. Every review's size is now the same stack: one `change` row
on the first review (`scripts/review/tools/revdiff.sh` `revdiff_size`), and on a
reply `this round` on top, `after review N` below it, and `original change` at
the bottom (`scripts/review-diff.sh`). Review rounds take the same order
(`scripts/review-round.sh` `size_rows`, `seed`). Only DIFF-38 and REVIEW-27 were
read against the code in this refresh.

### 2026-10-22 — Catch a placeholder cut at its token's own parenthesis (PREPARE-10a1)

STATUS.md updated: no new IDs, 320 held; PREPARE-10a1 amended.

A bare `anchor:` placeholder ends at the first `)`, so a token like
`anchor_items_anchor() {` was cut to `anchor_items_anchor(`, still resolved to
one line, and `--expand` left ` {)` in #155's description. `--check` and
`--expand` now report it as `unbracketed` (`scripts/deep-links.sh`
`run_resolution`, `tests/deep-links.test.sh`). Only PREPARE-10a1 was read
against the code in this refresh.

### 2026-10-21 — Stack each pass's size as bars (DIFF-38, REVIEW-27)

STATUS.md updated: +1 ID (DIFF-38, Covered), 319 → 320; REVIEW-27 amended.

A reply review's context file gave the whole change's size alone, and review
rounds reported each round as a percent of the CR in the next-round question,
which had to be read and compared in the head. Both now draw the whole change
and each pass as bars on one scale (`scripts/lib/size-stack.sh`). A reply's
state carries the snapshots of the reviews before it (`earlier`), so every pass
since the first has a row; a round's ledger records the CR's own size so
`review-round.sh sizes` can draw it. Only DIFF-38 and REVIEW-27 were read
against the code in this refresh.

### 2026-10-21 — Show a lone context file without the tree (DIFF-36)

STATUS.md updated: no new IDs, 319 held; DIFF-36 amended.

revdiff replaces the file tree with an outline of headings when the review holds
one unchanged markdown file, and a reply round with nothing changed and every
answer in `(context).md` is that review: the reply's headings read as files.
The adapter sets `REVDIFF_NO_TREE` when the context file is all the tree would
hold (`scripts/review/tools/revdiff.sh` `diff_tool_command`,
`tests/review-reply.test.sh`). Only DIFF-36 was read against the code in this
refresh.

### 2026-10-21 — Keep notes on the code they concern (UX-09)

STATUS.md updated: no new IDs, 319 held; UX-09 amended.

The first workaround for revdiff's `]` skipping notes outside hunks moved every
off-hunk note onto the nearest changed line no other note held. In a demo round
that put a note about line 7, already on screen in the first hunk, on a change 23
lines away, and left a note about line 18 where `]` skips it once both changes
were taken. A note near a change now stays put, a whole-file note moves onto its
file's first change, and a note far from every change goes to `(context).md`
with an excerpt, answered on its row (`anchor_items_onto_hunks`,
`scripts/review-round.sh` `seed`/`read`, `scripts/review-reply.sh`). Only UX-09
was read against the code in this refresh.

### 2026-10-21 — Answer on the note, and reach every note with ] (REVIEW-21, CONFIRM-12, UX-09)

STATUS.md updated: no new IDs, 319 held; REVIEW-21, CONFIRM-12, UX-09 amended.

Dropping an item meant opening `(context).md` with `e` and deleting its row, and
deleting the note alone was asked about. A note is now the answer: deleting it,
or replacing it with `drop`, `ignore`, `leave`, or `no`, drops the item; `ok`,
`yes`, `apply`, or 👍 keeps it; anything else changes it. The answer is read
where the note sat, so one that lost its `#N` header still counts. A batch reads
the same words (`scripts/lib/item-review.sh` `answer`). Notes outside a hunk move
onto the nearest free changed line, since revdiff's `]` steps only through hunks
(`anchor_items_onto_hunks`). Only the changed IDs were read against the code in
this refresh.

### 2026-10-21 — Judge the review's candidates before they reach the reader (REVIEW-19, 20, 24, 28, 29)

STATUS.md updated: +2 IDs (REVIEW-28, REVIEW-29, Covered), 317 → 319;
REVIEW-19, REVIEW-20 amended.

A review that once returned a couple of findings was returning dozens: four
independent lenses fed every candidate into a note at every site it touched,
with three severities, no check that a candidate was confirmed, no memory of
what the user had dropped, and fixes that drew findings the next round. The
candidates now pass one judgment against a two-tier bar (critical or
suggestion) with a risk score and no quota; an item gets one note; only a
critical item's local fix is applied; a dropped item is settled for later
rounds; and the next-round offer defaults to stopping. Only the changed IDs
were read against the code in this refresh.

### 2026-10-21 — Say where the review opened, and open a batch of new items (UX-11, DIFF-21)

STATUS.md updated: +1 ID (UX-11, Covered), 316 → 317; DIFF-21 amended.

A batch of two issue comments and a new issue returned `empty-range` and never
opened: every item was a new file, and the empty-range check read tracked
changes only. Under `--untracked` a new file other than `(context).md` now
counts (`scripts/review-diff.sh` `range_empty`, `tests/review-diff.test.sh`).

A review in an iTerm2 split sits beside the session rather than over it, so a
user coming back to the session's pane had nothing there pointing at it. The
probe now reports `REVIEW_HOST`, and the manifest opens with where the review
is. Only the new ID was read against the code in this refresh.

### 2026-10-21 — The next-round question carries its own context (REVIEW-24)

STATUS.md updated: no new IDs, 316 held; REVIEW-24 amended.

The offer of another round read "Run round 2 on #23, scoped to the round 1
commit (7abe057)", with the trend as a markdown table the prompt showed as raw
pipes. A user answering after time on another tab had to scroll back to learn
the repo, the CR, and what round 1 had done. The offer now names all three and
what another round would do, and gives the trend a line per round. Only
REVIEW-24 was read against the code in this refresh.

### 2026-10-21 — A reply in an unchanged file is quoted (UX-10)

STATUS.md updated: +1 ID (UX-10, Covered), 315 → 316.

A reply round opened every file that held an answer, changed or not, and revdiff
shows a file with no diff in full: a question answered without a change put the
whole file back in front of the reviewer with the reply partway down. Only the
new ID was read against the code in this refresh.

### 2026-10-21 — A review table says what the review is (CONFIRM-15, REVIEW-27)

STATUS.md updated: +1 ID (CONFIRM-15, Covered), 314 → 315; REVIEW-27 amended.

A round's `(context).md` opened on "Round 1 on sextant #23" and the item table,
so a reviewer coming back to a tab they had left could not tell what repo it
was, what opened the review, what the file was, or what quitting would do. The
round's table now opens with what `/anchor:review` found, what quitting leads
to (a commit to approve, or posts drafted for approval), and the repo, branch,
and CR; a batch's table says what opened it and that it is the guide. REVIEW-27
numbers a round only from the second on. Only the changed IDs were read against
the code in this refresh.

### 2026-10-21 — The review launch ends the turn (DIFF-02)

STATUS.md updated: no new IDs, 314 held; DIFF-02 amended.

A session asked `/anchor:commit`'s branch question after launching the review.
The reviewer left comments and closed revdiff, but the background call's
completion queued behind the open `AskUserQuestion`, so the verdict reached the
session only after the user dismissed the question. DIFF-02 now requires the
launch to end the turn, with every question settled before it
(`guides/running-a-review.md`, "Launch in the background"). Every skill that
launches a review already asks its questions before the launch or after the
verdict; only DIFF-02 was read against the code in this refresh.

### 2026-10-20 — Notes on the line they concern (UX-09)

STATUS.md updated: +1 ID (UX-09, Covered), 313 → 314. Only the new ID was
read against the code in this refresh.

### 2026-10-20 — Re-review a changeset as a reply (DIFF-37)

STATUS.md updated: +1 ID (DIFF-37, Covered), 312 → 313. Only the new ID was
read against the code in this refresh.

### 2026-10-19 — Milestones in a batch, one item review for batches and rounds, the header in the tree (ISSUES-13, 14, CONFIRM-08, 14, DIFF-36)

STATUS.md updated: +4 IDs (ISSUES-13, ISSUES-14, CONFIRM-14, DIFF-36, Covered), 308 → 312.
CONFIRM-08 now rests on notes on `(context).md`: the `(description)` block it
cited is written by a revdiff fork, and released revdiff never writes one.
DIFF-13 reworded: a commit message's buffer is git's `COMMIT_EDITMSG` and the
context below the scissors is a comment in the artifact's format
(`scripts/review/modes/edit.sh`, `tests/review-edit.test.sh`).
ISSUES-13 and ISSUES-14 cite the cookbook's "Milestone create and edit", which
reaches this branch with the cookbook change. Only the new IDs were read against
the code in this refresh.

### 2026-10-16 — Review a batch of edits in revdiff (CONFIRM-10..13)

STATUS.md updated: +4 IDs (CONFIRM-10..13, Covered), 304 → 308. Only the new IDs
were read against the code in this refresh.

### 2026-10-16 — Closing keywords in CR descriptions (PREPARE-19)

STATUS.md updated: +1 ID (PREPARE-19, Covered), 303 → 304. Only the new ID was
read against the code in this refresh.

### 2026-10-15 — Review in rounds, decided in revdiff (REVIEW-05, 07, 16, 17, 19..27, DIFF-35)

STATUS.md updated: +8 IDs (REVIEW-20..27, DIFF-35, Covered), 295 → 303. The
requirement for posting self-review findings as threads was removed and the IDs
after it moved down one, so REVIEW-19 onward name the round-based flow; audit
entries below this one use the earlier numbering. REVIEW-05 returns to Covered,
since `/anchor:review` stops without revdiff rather than walking a chat floor.
Only the changed IDs were read against the code in this refresh.

### 2026-10-14 — Reconciliation rebased onto 1.18.1

STATUS.md updated: the 2026-10-01 reconciliation (280 IDs) merged with the IDs
main added since (COMMIT-10a, REVIEW-20, DIFF-13a, 20a, 25b, 25c, 34, FORGE-10..12,
UX-02a, 02b, CONFIRM-07..09), 280 → 295. The header on main read 294 while its
rows summed to 297; the counts here are summed from the rows. CONFIRM-01 and
CONFIRM-02 return to Covered, since `resolve-feedback` now commits each round
through one commit review (CONFIRM-09).

### 2026-10-12 — Show the text before it publishes (CONFIRM-06..09, COMMIT-10a, COMMIT-13)

STATUS.md updated: +4 IDs (CONFIRM-07, CONFIRM-08, CONFIRM-09, COMMIT-10a, Covered), 290 → 294; COMMIT-13 reworded to show the amended message; CONFIRM-06 moved to Partial on #148. Only the changed IDs were read against the code in this refresh.

### 2026-10-09 — agterm reviews open in place, and say what opened them (DIFF-13a, DIFF-25c, DIFF-34)

STATUS.md updated: +3 IDs (DIFF-13a, DIFF-25c, DIFF-34, Covered), 284 → 287. Only the changed IDs
were read against the code in this refresh.

### 2026-10-06 — Collated review findings (REVIEW-20)

STATUS.md updated: +1 ID (REVIEW-20, Covered), 283 → 284. Only the changed IDs
were read against the code in this refresh.

### 2026-10-05 — An agterm host, and a host of the user's own (DIFF-25, DIFF-25a, DIFF-25b)

STATUS.md updated: +1 ID (DIFF-25b, Covered), 282 → 283; DIFF-25 and DIFF-25a
evidence names the agterm overlay host. Only the changed IDs were read against
the code in this refresh.

### 2026-10-01 — Wrong-answer bugs (CI-01, MERGE-03, 07, 09, RELEASE-03, 03b, DIFF-16, 18, REVIEW-08)

STATUS.md updated: 9 Partial → Covered; 222 → 231 Covered, 47 → 38 Partial.

Each was a helper reporting a confident answer the facts didn't support: "no
pipeline" for a read that failed (#46), "mergeable" for a PR GitHub blocks on a
failing check, `bump-commit` for a one-line `on: release`, a configured editor
for git's compiled default, an approval for a difftool review whose edits git
had discarded. A failed read is now `unreachable`, terminal, and blocks the
merge; checked live against GitHub with a bad token. The forge preflight #46
also proposes is not part of this.

### 2026-10-01 — Commit what was reviewed (COMMIT-04, 04b, 04d, 05, 14, RULE-05, DIFF-22)

STATUS.md updated: 7 Partial → Covered; 215 → 222 Covered, 54 → 47 Partial.

COMMIT-04d now applies to the flow's first staging: the review restages the
flow's own fixes, and COMMIT-04e stops anything staged after it. COMMIT-04e
gains the hook clause: the scratch-index commit let a `pre-commit` hook's
`git add` land in the commit unreviewed (#79), so a commit whose tree differs
from the one built is kept local with exit 71.

### 2026-10-01 — Contradictions resolved (TARGET-07, TARGET-09, COMMIT-17, PREPARE-10b, PREPARE-14, RELEASE-04, DIFF-11, DIFF-17)

STATUS.md updated: 2 IDs retired (COMMIT-17, PREPARE-10b), 282 → 280; 5 Contradicts → Covered (TARGET-07, PREPARE-14, RELEASE-04, DIFF-11, DIFF-17), 1 Partial → Covered (TARGET-09); no Contradicts remain.

The five were spec text that had fallen behind the code, and each was reworded to
what the code does. COMMIT-17 guarded a hook match on a heredoc'd message body,
which the file-based commit removed; PREPARE-10b fixed when placeholders expand,
which is a detail of opening the CR, and PREPARE-10 now states the outcome.
TARGET-09 closed in code: `scripts/deep-links.sh` takes `--repo` and
`scripts/mark-ready.sh` refuses an empty one.

### 2026-10-01 — Coverage refresh (spec-status)

STATUS.md updated: 45 Covered → Partial, 5 Covered → Contradicts (COMMIT-17, PREPARE-10b, PREPARE-14, DIFF-11, DIFF-17); 259 → 209 Covered, 10 → 55 Partial, 2 → 7 Contradicts; 5 needs-decision flagged. Every ID was read against the code in a full spec-sync; each row's gaps are under its Notes.

### 2026-10-01 — Commit what was reviewed (COMMIT-04e)

STATUS.md updated: +1 ID (COMMIT-04e, Covered), 281 → 282; DIFF-33's evidence
names the difftool limit as the verdict read from the working tree. Only the
changed IDs were read against the code in this refresh.

### 2026-09-30 — Partly staged commits (COMMIT-04d, DIFF-33)

STATUS.md updated: +2 IDs (COMMIT-04d, DIFF-33, Covered), 279 → 281; COMMIT-04b's
evidence now names the scratch-index commit; plugin version 1.14.0 → 1.15.2.
Only the changed IDs were read against the code in this refresh.

### 2026-09-29 — Merge through two helpers (MERGE-18)

STATUS.md updated: +1 ID (MERGE-18, Covered), 278 → 279.

A merge is terse and repeatable when its facts come from scripts: every run
makes the same two calls and shows the user the gate table and the prompts, not
the commands behind them. `scripts/merge-gates.sh` reads the CR, the checkout,
the gates, and the method; `scripts/merge.sh` merges guarded on the head SHA,
announces, and cleans up. The skill's three confirmations go through
`AskUserQuestion`.

### 2026-09-28 — Superseded pipeline watches and abbreviated shas (CI-15, CI-16)

STATUS.md updated: +2 IDs (CI-15, CI-16, Covered), 276 → 278.

The v1.15.0 release ran two watches on one commit: the one `/anchor:commit`
started on the notes push, and the one on the dispatched Release run. The
second was given `--sha 5a5a0b3` and reported `none` for a run that had
passed, because GitHub's `head_sha` filter matches the full sha only. CI-16
resolves the sha first. CI-15 settles which watch speaks: the newer pipeline,
with the older watch stopped. The watch procedure the skills each restated
moved into `guides/watching-a-pipeline.md` with it.

### 2026-09-28 — Chat feedback while a review is open (DIFF-32)

STATUS.md updated: +1 ID (DIFF-32, Covered), 275 → 276.

A review runs as a background call, so the user can still type in chat while it
is on screen, and nothing said what that feedback does to the open review.
Closing the review from the chat side risks losing what the reviewer has written
in it, so DIFF-32 leaves it open, halts, and asks for a second review once both
sets of feedback are applied. The review loop the five skills each restated
(probe, background launch, verdict mapping) moved into
`guides/running-a-review.md` with it, so the skills keep only their own
arguments, manifest, and what `approved` leads to.

### 2026-09-23 — Sanitizing what publishes, and one key shape (SANITIZE, CONFIG-16..20)

STATUS.md updated: +16 IDs (SANITIZE-01..11 Missing, CONFIG-16..20 Covered),
259 → 275.

A `/anchor:prepare-review` run put `gitlab.getty.cloud` in the Validation section
of [pwsh-gitlab#167](https://github.com/chris-peterson/pwsh-gitlab/pull/167), a
public GitHub PR. The hostname came from session context rather than from the
diff, which is the shape of the problem: the system drafts from whatever the
session holds, and a session working one repo routinely holds another's
hostnames, paths, and credentials. SANITIZE puts detection ahead of the CONFIRM
gate so the text the user approves is the text that publishes — deterministic
findings in a script, the replacement in the skill, shape-preserving placeholders
rather than prose, and a question where the replacement is not clear.

Writing the `deny` / `allow` keys exposed that there was nowhere in the key space
to say *at this destination*, the qualifier being a camelCase prefix on some
settings and a subsection on others. CONFIG-16..20 settle it on one rule and
carry the old names forward; the term is *qualifier* rather than *scope* because
`git config --show-scope` already means the local / global / system layer.
SANITIZE stays Missing — nothing detects yet.

The rework breaks existing configuration rather than shimming it. The `mr` / `pr`
keys are what settled that: they overrode the CR rules alone, where a forge
qualifier now covers every artifact published to that forge, so carrying one to
the other would apply a rule written for CR descriptions to commits and release
notes as well. A rename that does not preserve meaning is not one to perform on
the user's behalf, so every superseded name is reported and left alone.

### 2026-09-16 — Full spec-sync, and an approving reviewer's comment can direct the follow-up (DIFF-31)

STATUS.md updated: +1 ID (DIFF-31, Covered), 258 → 259; 9 Covered → Partial
(TARGET-03, TARGET-06, COMMIT-04b, RELEASE-03b, UX-02, DIFF-20, CONFIG-15,
CONFIG-15a, CONFIG-15b), 2 Covered → Contradicts (TARGET-07, RELEASE-04);
plugin version 1.12.0 → 1.14.0.

The header count had been reading 4 short of both the category table and the
spec's own inventory; the table and the spec agreed, so the header was the one
that moved.

DIFF-08 settled what a `changes-requested` verdict's comments mean and left the
approved case unstated, so a reviewer who signed off and asked for an issue got
their remark printed. The four skills that read the contract now carry it out.

### 2026-09-03 — The approval says where it lands (ISSUES-12)

STATUS.md updated: +1 ID (ISSUES-12, Covered), 252 → 253.

The drafted issue reached the user headed by `Labels: bug · Milestone: 1.14`,
which is the least of what they need to decide: a repo name never appeared, and
an issue filed against a resolved target repo looked identical to one filed
against the cwd. The presentation now opens with the destination as a link — the
project's issue list on a create, the issue itself on an update — and the title
sits above the metadata rather than under it.

### 2026-09-02 — The lifecycle facts a sibling can act on (EVENTS-01..17)

STATUS.md updated: +17 IDs (EVENTS-01..17, all Covered), −2 IDs
(MERGE-16, RELEASE-20 removed), 237 → 252.

The plugin already announced two facts and the category covering them did not
exist, so the contract behind them lived only in `scripts/announce.sh`'s header
and the manifest block it validates against. EVENTS now states it, and the key
set grew from the two CR-creation facts to the seven a consumer needs to follow
a change from filed to shipped: `issue.created`, `commit.pushed`, `cr.ready`,
`cr.merged`, and `release.created` join them.

Three of the five changed something beyond declaring a key.

`commit.pushed` needed an address, and nothing in the plugin derived one from
`origin` — `deep-links.sh` builds line anchors from a CR URL it is handed.
`scripts/lib/forge-url.sh` is that resolver, over the remote shapes a clone can
carry, and it drops credentials from a remote cloned with a token in it rather
than announcing them.

`cr.ready` names a transition, which meant finding every path that clears a draft
flag. There were two, reached from opposite directions: the self-review handoff
in `/anchor:review`, where the author is done and wants eyes on the change, and
`/anchor:merge`'s draft gate, where they are landing one that never left draft.
Both now call `scripts/mark-ready.sh`, which reads the flag itself — it flips
live, and a run announcing a transition that had already happened would report
one that did not.

`cr.merged` and `release.created` read their fields back from the forge rather
than from what the run knows. A merge time assembled locally records when anchor
heard rather than when the merge happened, and on the CI-owned release models the
workflow derives the version, so the release this run recommended is not
necessarily the one that published.

MERGE-16 and RELEASE-20 are gone with them. Each required a `tack` CLI call —
`tack done` plus `tack deliverable` after a merge, `tack link add` after a
release — which is the same fact `cr.merged` and `release.created` now carry, on
a path that does not name the consumer. `anchor` calls nothing of tack's and
declares no dependency on it; a plugin that wants the facts subscribes. The
capability the two requirements described is covered by EVENTS-13..16, and the
composition runs through the shared session rather than through either plugin's
CLI.

### 2026-08-31 — The review's second axis is a tool, and it is called one (CONFIG-15a, PREPARE-10a1, 13a)

STATUS.md updated: +2 IDs (PREPARE-10a1, 13a, both Covered), 235 → 237.

The half of a review the user picks was named `backend` in the report keys, in
the config keys, in the adapter directory, and in the prose around all three —
while every sentence explaining it reached for the word *tool*, because that is
what it is. `REVIEW_BACKEND` named `hx`; `anchor.diff.backend` named `revdiff`.
The keys now say `REVIEW_TOOL` and `anchor.{edit,diff}.tool`, the adapters live
under `scripts/review/tools/`, and the contract field is `tool`. The keys were
unreleased, so nothing carries the old spelling forward. The probe reports the
two answers together and the two sources after them, rather than interleaving
each axis with where it came from.

Two defects in the placeholder work surfaced while drafting this change's own
description with it. `stray_anchors` matched `anchor:` anywhere in the draft, so
a sentence naming `/anchor:prepare-review` was reported as broken placeholder
markup — a check finding fault in prose the author meant (PREPARE-10a1). And
`CURRENT_DESC_PATH` was an empty *string* wherever no CR was open, which the CR
opening last made the usual case; the review wrapper takes a pair of paths, so
the description review exited on a usage error instead of opening (PREPARE-13a).
The baseline is an empty file now, the way `release-recon.sh` has always supplied
the notes baseline.

A third surfaced the same way, pointing this description's own Review guide at a
regex line: `awk -v tok=` processes escapes in the assignment, so a token
carrying a backslash arrived with it stripped, matched nothing, and reported as
`unchanged` — the one diagnosis that sends the author hunting for a line already
in front of them. The token reaches the matcher through the environment now
(PREPARE-10).

### 2026-08-31 — The CR opens after the description is approved (PREPARE-03, 10a, 10b, 15a)

STATUS.md updated: +3 IDs (PREPARE-10a, 10b, 15a, all Covered; PREPARE-03,
10 and 15 rewritten), 232 → 235.

`prepare-review` opened the draft CR during recon because the Review guide's
deep links need the CR's URL, and the anchor cannot be computed before the CR
exists. That ordering cost twice: the author watched a `--fill` description —
the commit body — land under their name minutes before the real one replaced it,
and any later sweep over the links needed them in the loop again.

Placeholders break the dependency. A bullet's destination names a path and a
distinctive token from the target line, and resolving that token to a line needs
only `<base>...HEAD` — no URL. So the description is complete and checkable
before the forge holds anything, the author reviews it, and only then does
`--open` create the draft carrying their approved text. Expansion into anchors
follows, against the URL that just came back, with no further approval to ask
for: the text they signed off on is unchanged and the links were resolved before
they read it.

Removing the hand-read line number is the second half, and the one the issue was
filed for (#40). The prefix was already derived and exact; the `R<n>` appended to
it was read off the diff, and a wrong one still resolves — the forge scrolls to a
line the bullet is not describing, which nothing about the rendered link reveals.
Seven of thirteen links in one description had drifted. PREPARE-10a is the rule
that keeps resolution from reintroducing the same failure quietly: several
matching lines, or none, halts with the candidates rather than taking the first
or reducing to a file-level link.

PREPARE-15 becomes the placeholder check, which needs no CR and so runs before
the review; PREPARE-15a keeps `--verify` as the backstop for descriptions that
predate the convention, and closes the hole all four of its checks shared — each
questioned an anchor's *number* and took its *shape* as given, so
`…#<hash>#L743`, the shape a reflex `#L<n>` produces, returned zero suspects.

### 2026-08-31 — git's difftool becomes a backend, graded on what the reviewer wrote (DIFF-18, UX-08)

STATUS.md updated: +1 ID (UX-08, Covered), 231 → 232; DIFF-18 rewritten.

DIFF-18 kept git's difftool off the menu because it speaks no contract: a
changeset on screen with no verdict behind it ends in "you saw it, approve?".
That reasoning only covers a difftool used for *reading*. A reviewer can write
through one — `--dir-diff` symlinks the working-tree side — and a write is an act
where reading is not, which is the same signal the editor mode had just been
rebuilt on. So the tool now opens, `diff.tool` is honored as the mirror of
`edit` falling through to `core.editor`, and the verdict is read from the files:
anchor snapshots them before launching, and each one the reviewer changed comes
back carrying the diff of what they wrote.

That removes the marker convention the idea seemed to need. A reviewer types a
fix into the code, or a question in whatever comment syntax the file already
uses, or a `TODO:` — all one signal, and UX-08 makes reading it the model's job:
keep the fixes, answer the questions, and take their comment lines out before
committing, verified against the touched files rather than trusted, since a
question left behind reaches the default branch.

### 2026-08-31 — Mode and backend are two axes, and one adapter per mode (CONFIG-15, CONFIG-15a, CONFIG-15b, DIFF-03, DIFF-11, DIFF-17)

STATUS.md updated: +1 ID (CONFIG-15b, Covered), 230 → 231; CONFIG-15 and
CONFIG-15a rewritten, DIFF-03, DIFF-11 and DIFF-17 amended.

`anchor.reviewBackend` took `editor` or `revdiff`, which are not the same kind of
thing: one names the shape a review takes, the other a program. The conflation
cost two things. There was nowhere to say *which* viewer, so a second diff tool
had no key to be selected by. And the editor's own name had to ride a parallel
set of report fields — `REVIEW_EDITOR`, `REVIEW_EDITOR_SOURCE`,
`REVIEW_EDITOR_AVAILABLE` — restating on a second axis what `REVIEW_BACKEND`
already answered for viewers.

The two questions are now asked separately, and only one of them is the user's.
The **mode** has no key: which shape fits is a property of the review, so the
subject answers it and a key could only ask for the shape that does not fit. The
**tool** is where preference belongs, one symmetric key per mode —
`anchor.edit.backend` above git's chain, `anchor.diff.backend` above revdiff. The
probe reports one mode axis and one backend axis, so `REVIEW_BACKEND` names `hx`
in edit mode and `revdiff` in diff mode rather than naming an adapter, and the
editor-only keys are gone. Substitution follows the split: a mode gives way to a
mode, a viewer to a viewer, and neither crosses. The superseded key is reported
as doing nothing, naming the two that replaced it.

The adapters follow the same seam. `review/<mode>.sh` owns what every tool in
that mode needs alike — finding the binary, putting a terminal up, seeding the
header, shaping the result — and `review/tools/<tool>.sh` owns only that
tool's invocation, output parsing, and exit-status mapping. A second viewer is a
file beside revdiff's rather than a second copy of the mode.

### 2026-08-31 — The subject picks the backend, not the skill (CONFIG-15, CONFIG-15a)

STATUS.md updated: +1 ID (CONFIG-15a, Covered), 229 → 230; CONFIG-15 amended.

The default was a list of skill names: `prepare-review`, `issue` and `release`
got the editor, everything else the diff viewer. That answered for the artifact
a skill usually drafts rather than the review in front of it, and the same skill
draws both shapes — `/anchor:issue` files a body from nothing and also revises
one that exists, and a description re-opened after `changes-requested` is a
revision of the draft the reviewer already graded. One question replaces the
list: has this review got a diff to show? A single file with no prior version has
none, and the viewer would mark every line of it as added; anything else has real
hunks, which is what per-hunk annotation is for. A git range always names a base,
so it lands on the viewer without a special case.

CONFIG-15a follows from where the answer now comes from. The pre-launch probe
resolved from the skill name alone, which was enough while the skill decided; a
subject-driven default makes a bare probe answer for a review nobody is about to
open, so the consumers pass the mode and both paths.

### 2026-08-31 — The save is the verdict (DIFF-14)

STATUS.md updated: no new IDs, 229 held; DIFF-14 amended.

Emptying the buffer was the only way to stop a flow from inside the editor, and
the gesture is both awkward to perform and easy to perform by accident — the
abort a reviewer reached for most often was the one they never meant. Quitting,
meanwhile, approved: an editor left open behind another window and closed hours
later graded the draft as read. The save now answers for both. It costs the same
keystroke as a quit, it is an act rather than the absence of one, and it is read
from the buffer rather than from how the editor left — so a draft saved into a
pane that was then closed is still the reviewer's answer, where the exit status
alone had thrown it away.

### 2026-08-31 — The backlog gets its own skill name and prefix (BACKLOG-01..06)

STATUS.md updated: no new IDs, 229 held; the survey's six moved from
ISSUES-07..12 to BACKLOG-01..06 and the triage five from ISSUES-13..17 to
ISSUES-07..11. **The old numbers are reused, not retired** — an ISSUES-09 cited
in an entry below this one is the ranking rule, not the milestone rule.

`/anchor:issues` sat one letter from `/anchor:issue`, so the skill that reads and
the skill that writes were told apart by a plural. The survey is `/anchor:backlog`
now, and SPEC.md splits along the same line: ISSUES is what authoring one issue
does, BACKLOG is the backlog it lands in — survey today, and whatever grooming
and sequencing land there next.

### 2026-08-30 — An editor that never answered says so (DIFF-14)

STATUS.md updated: no new IDs, 229 held; DIFF-14 amended.

Closing the review pane rather than quitting the editor reported "the editor
exited 125" — a status the editor never returned, since it was still running
when its terminal went away. 125 also stood for two other causes, so the number
could not have been read even by someone who knew what it meant. The three now
come back named (`pane-closed`, `no-pane`, `no-host`), and a pane taken down
mid-edit is reported as re-openable: the tool works, the draft is intact, and
walking the fallback ladder there would hand the user a chat walkthrough of
something their editor was about to show them. The diff viewer had the same gap
one file over — its own `absent` / `no-host` were named, but a closed pane
reached it as the split runner's number — so both adapters answer alike.

### 2026-08-30 — The editor rung a terminal host picks, and the key that would pick it (DIFF-13, DIFF-16, DIFF-24, UX-07)

STATUS.md updated: no new IDs, 229 held; DIFF-13, DIFF-16, DIFF-24 and UX-07
amended.

DIFF-16 put a blocking VS Code above git's compiled default because `vi` needed
a terminal nothing was putting up. Two days later DIFF-25 gave anchor a terminal
to put up — a tmux popup, a split of the calling iTerm2 session, labelled and
focused — and the ordering was never revisited, so a user who configured nothing
got a GUI window behind their terminal on a machine where `git commit` opens an
editor in the pane they are already looking at. The rung now turns on whether a
terminal can be hosted, and the GUI editor is what answers when none can.

UX-07 grew the other half of that: the ladder is invisible from inside the tool
it lands on, so the launch names the key that would settle it — for the
defaulted half only, which retires the hint as soon as the user sets one.

DIFF-13's buffer takes the artifact's own extension. Three of the four artifacts
are markdown and the buffer carried no extension at all, so an editor opened
them as plain text with no way to reach its markdown preview.

### 2026-08-29 — Review-launch manifest and the push's CR link (spec-status)

STATUS.md updated: +2 IDs (UX-07, RULE-04a Covered), 227 → 229. UX-07 requires the launch message to carry a manifest of what is under review, which reverses the "don't announce the launch" line the five launch blocks carried: the tool shows one file at a time, so the set was the one thing nothing put in front of the reviewer. RULE-04a rules out the CR-creation URL a push prints, after a session offered it in place of `/anchor:prepare-review`.

### 2026-08-29 — Coverage refresh (spec-status)

STATUS.md updated: +1 ID (DIFF-30 Covered), 226 → 227; plugin version 1.9.0 → 1.9.1. DIFF-30 requires the split to take the input focus: iTerm2 creates a scripted split without selecting it, so the review drew in a pane the keyboard never reached. DIFF-26 gains the working directory, since the pane starts wherever iTerm2 stands and re-resolves the refs there.

### 2026-08-28 — Coverage refresh (spec-status)

STATUS.md updated: +1 ID (DIFF-29 Covered), 225 → 226; plugin version 1.8.0 → 1.9.0. DIFF-29 requires the split to carry the calling session's tab label, since the pane opens focused and a tab drawn from a session with no label of its own goes blank for the length of the review.

### 2026-08-27 — Coverage refresh (spec-status)

STATUS.md updated: +5 IDs (DIFF-24 Partial, DIFF-25..28 Covered), 220 → 225; plugin version 1.7.0 → 1.8.0. DIFF-24 requires the backend probe to run under the skill the launch uses and the consumer to name the tool it opens; `prepare-review` and `commit` do not yet meet it. DIFF-25..28 move both review backends onto one split runner: the review opens in a split of the calling session rather than a window, carries the caller's environment into it, drives revdiff directly instead of through that plugin's launcher, and waits on the reviewer without an elapsed-time cap.

### 2026-08-26 — Coverage refresh (spec-status)

STATUS.md updated: -1 ID (TARGET-08 retired, TARGET-09/10 renumbered to 08/09),
209 → 208. Worktree isolation left the plugin, so the requirement that a write
flow against a non-cwd repo run in a dedicated worktree has no subject.

### 2026-08-25 — Coverage refresh (spec-status)

STATUS.md updated: coverage unchanged (209 Covered); DIFF-16 amended.

The compiled-default rung is now read with a pinned `TERM` and with the
environment's own editors unset. git names no editor at all on a dumb terminal,
which is every CI step and every agent harness without a controlling TTY, so the
rung DIFF-16 added resolved to nothing exactly where it was meant to matter —
`scripts/lib/review-editor.sh` (`anchor_editor_resolve`),
`tests/review-edit.test.sh` (the resolve chain, run under both `TERM` states).

### 2026-08-25 — The editor takes the drafted documents (DIFF-23, DIFF-11, DIFF-16, DIFF-17, CONFIG-15)

STATUS.md updated: +1 ID (DIFF-23, Covered), 208 → 209; DIFF-11, DIFF-16,
DIFF-17 and CONFIG-15 amended.

`prepare-review`, `issue`, and `release` open one drafted document each, and
their `--files` pair is text against text — so the diff viewer marked every line
as added and asked the reviewer to comment their way to a rewrite of prose
neither side of which they had read. Their skill prose said as much: two of them
carried a sentence explaining that the review reads as all additions. Those three
now default to `editor`, where the buffer *is* the artifact; `commit` and
`review`, whose subject is a changeset, keep the viewer.

DIFF-16 grew the rungs that make that default reachable. The chain stopped after
`EDITOR`, so a session exporting `GIT_EDITOR=true` with no `core.editor` — the
common agent-harness shape — reported no editor on a machine where `git commit`
opens `vi`. DIFF-11 gained the other direction of substitution for the same
reason: a *defaulted* editor with nowhere to open gives way to an installed
viewer, while a *configured* one is kept and reports what is missing.

DIFF-23 came from the re-review path, where the left-hand side stayed the
description the forge holds, so a second pass showed the same comparison the
first one had already answered instead of what the feedback changed.

### 2026-08-24 — moor retired (spec-status)

STATUS.md updated: -1 ID (DIFF-10 retired), 209 → 208; plugin version 1.6.1 →
1.7.0. `scripts/review/moor.sh` and `scripts/lib/review-difftool.sh` are gone —
the `difftool` result shape existed only because moor's adapter reached moor
through `git difftool`, so DIFF-10 no longer has a producer. `revdiff` and
`editor` are the backends.
### 2026-08-24 — Target resolution decoupled from tack (spec-status)

STATUS.md updated: +2 IDs (TARGET-11, TARGET-12), TARGET-01/04/05 reworded, plugin version 1.6.1 → 1.7.0. Resolving a named target repo now runs through `gh` and `glab` rather than tack's repo db, so the capability no longer depends on a plugin the user may not have installed; tack remains an optional dependency for recording CRs and releases against a route.
### 2026-08-24 — Settable review qualities and self-review (spec-status)

STATUS.md updated: +6 IDs (REVIEW-03a, 15..19, all Covered), 209 → 215; plugin
version 1.6.1 → 1.7.0. REVIEW-03 split so that self-authorship selects a mode
instead of raising a confirmation, and REVIEW-08 now states the placement rule
the retired `templates/cr-review.md` carried.

### 2026-08-22 — CLI retired (spec-status)

STATUS.md updated: -16 IDs (CLI-01..16 retired), 225 → 209. `scripts/anchor`,
`commands/anchor.md`, and their tests are gone; the CLI category no longer has
an implementation to cover. (The prior header read 224 against a category
table that already summed to 225; this refresh corrects it.)

### 2026-08-20 — Prescribed paths a caller can grant (UX-06, UX-06a)

STATUS.md updated: +2 IDs (UX-06, UX-06a, both Covered), 222 → 224. The six
prescribed `mktemp` sites moved from `${TMPDIR:-/tmp}` to a literal `/tmp`,
which an `Edit(//tmp/**)` grant reaches on macOS where the template did not;
`scripts/lib/tmpfile.sh` keeps `$TMPDIR` and now states why the two differ.

### 2026-08-20 — Repeatable path staging (COMMIT-04c)

STATUS.md updated: +1 ID (COMMIT-04c, Covered), 221 → 222. COMMIT-04a was
narrowed to a path with no change at all, and the already-fully-staged case
moved to COMMIT-04c: `git add` is fatal on a path git has already staged as a
deletion or as a rename's old half, and both the commit and review flows stage
their path list twice by design.

### 2026-08-20 — Coverage refresh (spec-status)

STATUS.md updated: +6 IDs (ISSUES-13..17, PREPARE-18, all Covered), 215 → 221;
plugin version 1.6.0 → 1.6.1. The `issue` and `prepare-review` skills now read
the project's labels and open milestones and apply what fits, so an issue or a
CR arrives triaged rather than bare.

### 2026-08-17 — Coverage refresh (spec-status)

STATUS.md updated: +6 IDs (TARGET-10, DIFF-21, DIFF-22, COMMIT-04a, COMMIT-04b,
PREPARE-06a, all Covered), 209 → 215; plugin version 1.5.0 → 1.6.0. COMMIT-04
was reworded: staging names its paths rather than `git add -A`.

TARGET-10 and DIFF-21 came from a review that ran against the working-directory
repo because `--repo` trailed the mode flag. The staging IDs came from the same
tree: two sessions sharing it, where a whole-tree add put one session's files
into the other's review and commit.

### 2026-08-15 — Coverage refresh (spec-status)

STATUS.md updated: +16 IDs (CLI-01..16), 193 → 209; every other row unchanged.
The CLI category arrived with `scripts/anchor`, its slash shim, and the
freshness hook.

### 2026-08-15 — The difftool leaves the menu (DIFF-18, DIFF-10, DIFF-11)

STATUS.md updated: no ID count change, 193; DIFF-18 rewritten, DIFF-10 and
DIFF-11 amended.

Demoting the difftool to selectable-but-never-automatic (below) kept the option
open on the theory that someone might want it deliberately. Reviewing the
result: it is a disconnected experience — the diff opens in a window that
reports nothing back, so the flow lands in the fallback ladder anyway, having
first primed the user to say yes. That is the rubber stamp the verdict contract
exists to prevent, and leaving it selectable meant a config key could still
reach it. `scripts/review/git.sh` is gone and DIFF-18 now records the absence
rather than the adapter, so re-adding it argues against a requirement rather
than filling a gap.

The difftool does not disappear from the codebase: moor's adapter drives `git
difftool` to reach moor, so an absent or unconfigured moor still leaves one on
screen. That case is DIFF-10's, reworded from "the configured difftool" — which
no longer exists — to a launch that reaches one, and its result now names the
ladder rather than the direct question DIFF-20 forbids. It kept its old wording
("ask the user directly") a day past the pivot that outlawed it.

### 2026-08-13 — A fallback ladder instead of a difftool rung (DIFF-20, DIFF-11, DIFF-17, DIFF-18)

STATUS.md updated: +1 ID (DIFF-20, Covered), 192 → 193; DIFF-11, DIFF-17 and
DIFF-18 amended in place.

The bottom rung of the install ladder was measured against what it produces. A
difftool review shows the diff and then reports `no-verdict`, so the flow ends
in the same chat question an absent viewer would have asked — except the user
has now read something, and the natural next question is "you saw it, approve?".
That converts a tooling failure into an approval, which is the outcome the
verdict contract exists to prevent. So nothing degrades into `git` any more; it
joins `editor` as selectable-but-never-automatic, and DIFF-20 defines what
happens below a viewer instead.

The editor rung needs a probe it did not have. `--print-backend` treated the
editor backend as always available because it has no binary to look for, which
is true and useless: what decides the rung is whether a launch would *reach* an
editor — one resolvable per DIFF-16, and a host to open it in. Both halves moved
to `scripts/lib/review-editor.sh` so the probe and the adapter answer from the
same code, and the probe reports the result on its own axis.

`tests/review-edit.test.sh` was passing by coincidence of the environment: its
per-skill cases assert `backend == revdiff` while running against the ambient
PATH, and DIFF-11's resolution had made the host's installed set load-bearing.
On a machine with moor installed — every session has the plugin's own `bin/` on
PATH — it substituted moor and the cases failed; CI stayed green only because an
ubuntu runner has neither viewer. Pinned with a stub viewer dir and a no-op
`GIT_EDITOR`, alongside the `GIT_CONFIG_GLOBAL` pin that was already there.

### 2026-08-12 — Reviewing someone else's change request (REVIEW-01..14, DIFF-19)

STATUS.md updated: +15 IDs (REVIEW-01..14 and DIFF-19, all Covered), 177 → 192.
`anchor` covered the change lifecycle from the author's side only; a CR number
or URL from a teammate had no entry point, and findings landed in chat where the
author never saw them. The new category is the write half of a seam whose two
ends already existed — `deep-links.sh` builds line anchors for the authoring
side, `resolve-feedback` parses threads off a CR for the reading side.

Two requirements carry the design decisions the issue left open. REVIEW-05/06
make the diff presentation unfiltered and unskippable and treat an `incomplete`
verdict as a halt: a review that saw part of a change and signed off on all of
it is the rubber-stamp the step exists to prevent, and `reviewCompleteness:
null` says unmeasured rather than complete. REVIEW-13 keeps the forge verdict
out of the skill — leaving comments and recording an approval are separate acts,
and only the second is irreversible.

REVIEW-11 exists for the failure the issue named: a CR whose head moves
mid-review anchors every comment to a stale SHA. The head is pinned when the
diff is fetched and re-read before the first write, and a mismatch refuses
rather than re-anchoring by guess.

### 2026-08-12 — A `git` backend for the no-viewer fallback (DIFF-18)

STATUS.md updated: +1 ID (DIFF-18, Covered), 176 → 177. Degrading to git's
difftool ran through moor's adapter, which drives `git difftool` on its way to
reading moor's sidecar. That worked, but it made `moor` name two things — a
backend the user selects and the fallback nobody does — and it only worked while
git had a difftool to resolve: with `diff.tool` and `merge.tool` both unset, git
falls back to vimdiff, which waits on a terminal a CI job hasn't got, so the run
hung until the job was cancelled.

`scripts/review/git.sh` now owns that path. Where the configured backend's own
tool is the missing one, the dispatcher keeps that backend instead, so the report
names the absent tool rather than saying only that some difftool closed.

### 2026-08-12 — An editor review backend, selectable per artifact (DIFF-13..17, CONFIG-15)

STATUS.md updated: +6 IDs (DIFF-13..17 and CONFIG-15, all Covered), 170 → 176.
DIFF-16 and DIFF-17 exist for the backend's quiet failure mode: an editor that
never opened leaves the draft untouched, which is what an approval also looks
like.

### 2026-08-12 — A verbosity dial per artifact (CONFIG-11..14)

STATUS.md updated: +4 IDs (CONFIG-11..14, Covered), 166 → 170; plugin version
1.4.0 → 1.5.0. CONFIG-07's default moved 50 → 25 with no coverage change. The
header count also corrected: it read 162 against a category table that already
summed to 166.

### 2026-08-11 — Coverage refresh (spec-status)

STATUS.md updated: +1 ID (CMT-22, Covered), 161 → 162.

### 2026-08-10 — Coverage refresh (spec-status)

Coverage 160 → 161, plugin version 1.3.0 → 1.4.0. PREP-17 added: GitHub carries no
per-PR branch-deletion preference, so an opened PR reports the repo-wide setting
and the skill offers to turn it on rather than leaving the user to find the
surviving branch after the merge.

### 2026-08-06 — Ungraded comments, and an absent verdict halts (REV-08, REV-12)

Coverage 159 → 160. REV-12 added: a dispatcher that exits before printing
`REVIEW_VERDICT` leaves silence, which every consumer now reads as `no-verdict`
and verifies in chat rather than proceeding. REV-08 rewritten — moor stopped
grading comments (its `IM.OUT-02a`: "Comments carry no severity field"), so
`severitySource`, per-comment `action`, and `capabilities.gradedSeverity` are gone
from the adapters, the skills, the tests, and the docs; whether feedback blocks is
the verdict's answer alone. CMT-15 reworded off "fix-now comments" onto the
verdict. The docs-site playback frames in `plugin.yml` keep `action: fix-now`:
the marketplace session player dereferences `f.comment.action.replace(...)` with
no guard, so dropping the field throws and the frame stops rendering. Removing it
needs the player to tolerate its absence first — a change in the
`claude-marketplace` repo, not this one.

### 2026-08-06 — Approval before publishing (CONFIRM-01..06)

Last audit 2026-08-05 → 2026-08-06, plugin version 1.2.0 → 1.3.0; coverage 153 →
159. `resolve-feedback` holding reply bodies for the author's approval was the
prompt, but the gate isn't a feedback concern: every artifact anchor writes —
commit message, CR description, issue body, reply, release notes — publishes
under the user's credentials in their name. New CONFIRM category rather than an
FDBK row, since FDBK-04 confirms dispositions and CONFIRM-03 is precisely that
approving a disposition is not approving the prose. All six were already
implemented across the five skills; this documents them.

### 2026-08-05 — CR description verbosity (CONF-07..10)

Coverage 149 → 153, plugin version unchanged at 1.2.0. Four IDs for the
`anchor.crVerbosity` dial. CONF-08 abbreviates prose and CONF-09 keeps section
presence with the template's conditions and `reviewBudgetMins`, so the dial
cannot cost coverage; the old CONF-09 (length-not-register) is now CONF-10.

### 2026-08-05 — Coverage refresh (spec-status)

Last audit 2026-08-03 → 2026-08-05, plugin version 1.1.2 → 1.2.0; coverage 140 →
149. Nine IDs added for the post-push pipeline report: PIPE-10..14, CMT-21,
PREP-16, FDBK-09, CONF-06.

### 2026-08-03 — Coverage refresh (spec-status)

Last audit 2026-07-28 → 2026-08-03, plugin version 1.0.1 → 1.1.2; coverage
unchanged at 140 across 13 categories. CMT-01/CMT-02 reworded and CMT-16 refilled
for the recon-before-tests reorder, which keeps CMT contiguous at 20.

### 2026-07-28 — Pipelines resolve by commit, not by ref (PIPE-07, PIPE-08)

`pipeline-status.sh` asked GitHub for `gh run list --branch <branch>` and GitLab
for `pipelines?ref=<branch>`, then matched the commit within that ref's runs. A
run fired by a published release carries the *tag* as its branch, so watching the
v1.1.0 release run under `--branch main` reported `none` for a run that was for
exactly that commit. Both lookups now filter by commit sha (PIPE-07), which the
release-event fixture in `tests/pipeline-status.test.sh` pins. Doing so surfaced
the neighbor question: a GitHub commit has one run per workflow, and taking the
most recent of five reported whichever finished last. The verdict is now a fold —
each workflow's latest attempt, then the least-settled and worst-off run speaks
for the commit — with `--workflow` to scope it to one, which is how `release`
watches the release run and not a workflow that shares its commit (PIPE-08). The
fold is `pipeline`'s answer, not every caller's: `merge`'s gate asks for the
commit's most recent run alone (`--single-run`, PIPE-09), leaving "did every
required check pass" to the forge's own merge check that step 1a already reads.
139 requirements across 13 categories.

### 2026-07-28 — TGT-01 closed for `pipeline`

TGT-01 Partial → Covered: `skills/pipeline/SKILL.md` now resolves a name argument
through `scripts/resolve-target.sh` and acts on `TARGET_VIA`, with the
session-touched substring match kept as the `cwd` fallback (TGT-05). `pipeline`
reads a work tree, so an empty `TARGET_LOCAL` stops rather than falling through to
the cwd repo. Every skill now shares the same resolution path.

### 2026-07-28 — Coverage refresh (spec-status)

TGT-01 Covered → Partial: `pipeline` resolves a name argument by session-touched
substring match only, skipping the tack repo-db lookup the requirement specifies
and the other seven skills perform. REL-01..20 verified against
`skills/release/SKILL.md`, `scripts/release-recon.sh`, and `skills/merge/SKILL.md`
(REL-19); all Covered.

### 2026-07-28 — Release skill added (REL)

Added the `release` skill (`REL-01..20`), the step after `merge`: it establishes
the repo's **release model** — who owns the version bump — then recommends a
semver bump, drafts user-facing notes, and publishes along that model's path.
`scripts/release-recon.sh` supplies the model plus the manifest, its generating
descriptor, the version history, the bump convention, and the shipping range in
one pass (REL-01, UX-05); `guides/release-models.md` carries the per-model
procedure and traps. The model detection reads the CI workflow's *trigger* block
rather than grepping for `release`, so a job named `release` isn't mistaken for a
trigger (REL-03) — the case `tests/release-recon.test.sh` pins along with the four
model verdicts. Where a workflow owns the bump, the skill publishes and never
hand-edits the manifest (REL-04); where it doesn't, the bookkeeping lands through
`/anchor:commit` (REL-17). `merge` names `release` as the next step but does not
cascade into it (REL-19) — publishing is a deliberate act, and several merges
commonly batch into one release. Requirement rows added by hand alongside the code
change. 136 requirements across 13 categories.

### 2026-07-27 — The CR description is reviewed in the tool

`prepare-review` presented the drafted description by running
`git diff --no-index` and then asking whether to write it — output that reaches the
model, not the user, who saw a collapsed stub and a confirmation prompt for prose
they had not read. PREP-13 now requires the in-tool review (the same shape
`/anchor:commit` uses for the commit message) before any write prompt, with PREP-14
covering the text-in-reply fallback when no backend is installed or no CR exists.
UX-04 states the underlying rule for every skill; UX-05 requires reading values the
recon block supplies rather than re-deriving them, which is what `FILE_LINKS`
(PREP-10, `scripts/deep-links.sh`) now does for deep-link anchors on both forges.
CMT-20 covers the same theme on the commit side: the test gate reads the runner's
exit status on the first invocation instead of its output, which had cost a second
full run of the suite. PREP-15 closes the half `FILE_LINKS` leaves open: the prefix
is derived and exact, while the `R<n>` the author reads off the diff is hand-work
that drifts silently, so `deep-links.sh --verify` reads each line part back against
the tree. 116 requirements across 12 categories.

### 2026-07-21 — Tool-agnostic review contract (REV)

Renamed RVEW → REV and rewrote it as a tool-agnostic review contract. A dispatcher
(`review-diff.sh`) resolves the diff range and selects the backend
(`anchor.reviewBackend`, default moor); a per-backend adapter
(`scripts/review/{moor,revdiff}.sh`) normalizes the tool's output to a four-value
verdict (`approved` / `changes-requested` / `incomplete` / `no-verdict`) plus
graded-or-inferred comments, nullable completeness, and a capabilities descriptor.
Adds revdiff as a second backend. The commit / prepare-review / issue review steps
read the normalized verdict. The shape borrows from SARIF, reviewdog, and the
forge review APIs. 111 requirements across 12 categories.

### 2026-07-17 — Merge skill added

Added the `merge` skill (`MRG-01..16`) — the terminal lifecycle step that lands an
approved CR: checks the ready/mergeable/pipeline/approvals/threads gates (waiting on
the pipeline via `pipeline-status.sh --watch`), merges with a commit-preserving merge
commit (`--no-ff`) unless the project/CR is configured otherwise, via `gh`/`glab`, then returns to the default
branch and deletes the merged branch. Canonical merge/approval/mergeable invocations
added to `guides/forge-cookbook.md`. Requirement rows added by hand alongside the code
change; run `/sextant:spec-status` for a full re-audit. 107 requirements across 12
categories.

### 2026-07-14 — 1.0 commit/review redesign (spec ahead of implementation)

Reworked the commit and review-request flow toward a 1.0 release. `/anchor:commit`
becomes review-first and commit-and-push: it reviews the pending changeset (working
tree vs `HEAD`) before committing, then commits and pushes in one step (CMT-14/15
rewritten, CMT-18/19 added); fix-now now edits the working tree and re-reviews
rather than amending a committed checkpoint. The `--preview` mode is retired, and
its requirement removed. `prepare-review` keeps its name but is reworked to operate only
on an already-pushed branch — it opens the draft CR but never pushes and imposes
no review gate (the pre-push review gate PREP-03/04 is retired); the push moved
into `/anchor:commit`. RULE-04 and the Skill concept updated to match.

The implementation landed on the `1.0` branch in the same pass: `/anchor:commit`
reviews then commits-and-pushes and `--preview` is gone, so the CMT, PREP, and
RULE rows are Covered again; version bumped to 1.0.0.

### 2026-07-11 — Issues skill added

Added the `issues` skill (`ISS-07..12`) and reframed `issue` as file-a-new-issue,
delegating duplicate discovery to `issues` (`ISS-03` rewritten). The former `ISSU`
category absorbed the new requirements to become a single `ISS — Issues` category
covering both skills. Requirement rows added/edited by hand alongside the code
change; run `/sextant:spec-status` for a full re-audit. 91 requirements across 11
categories.

### 2026-07-08 — Initial extraction

Spec bootstrapped from the implementation via
`/sextant:spec-req init from implementation`. 85 requirements across 11
categories, all Covered by the skill / rule / script they were derived from.

## How to use this file

When you implement a new requirement, change the row's status and add an
evidence pointer. When an audit reveals drift, update the row to **Partial**
or **Contradicts** with a one-line note.
