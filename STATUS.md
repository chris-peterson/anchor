# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).

**Last audit:** 2026-09-03
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 1.12.0
**Coverage:** 253 Covered, 1 Partial, 0 Missing/Contradicts

The implementation is the plugin itself — the skill prompts under
`skills/`, the ambient rules under `rules/`, and the helper scripts under
`scripts/`. These requirements were reverse-engineered from that documented
behavior, and the 1.0 commit/review redesign (see audit history) has since
landed in the source, so each is Covered by the skill / rule / script it maps
to. Treat coverage as a draft to review against the implementation, not an
audited ledger.

## Status by category

| Prefix | Count | Status | Notes |
|--------|------:|--------|-------|
| TARGET-01..11 | 11 | All Covered | Target resolution — `scripts/resolve-target.sh`, each `skills/*/SKILL.md` "Target repo"; every skill routes a name argument through `resolve-target.sh`. `--repo` is read at any argv position and an unrecognized argument is an error rather than a dropped token, so an appended retargeting flag cannot leave a helper on the cwd repo while the flow uses the target (TARGET-09) — `scripts/review-diff.sh` (context-flag pass, `expect_consumed`), `scripts/look-ahead.sh`, `tests/review-diff.test.sh`. A name resolves through the forge CLIs anchor already requires, over the repos reachable on each host `gh auth status` / `glab auth status --all` report as logged in, so no sibling plugin gates the capability (TARGET-01) — `scripts/resolve-target.sh` (`authed_hosts`, `load_hosts`). A bare name matches on the basename exactly and case-insensitively, which is what separates `cloud-toolbox` from the `pwsh-toolbox` GitLab's substring search returns alongside it (TARGET-10) — `scripts/resolve-target.sh` (`collect`, `lower`). `TARGET_LOCAL` holds the working directory's repo only when its `origin` is the repo that resolved, an unauthenticated host is skipped, and a lookup with no host to query says so rather than reporting no match (TARGET-11) — `scripts/resolve-target.sh` (`local_checkout`, `fall_back_to_cwd`) |
| COMMIT-01..22 (+04a, 04b, 04c) | 25 | All Covered | Review-first commit-and-push flow (1.0), recon before tests, pipeline watch after the push (COMMIT-21), and the direct-to-default choice described as landing without a CR rather than as bypassing review (COMMIT-22) — `skills/commit/SKILL.md`, `scripts/{commit,commit-preflight,look-ahead,squash-check,pipeline-after-push}.sh`. Staging names its paths instead of adding the whole tree, stops on a path with no change at all, scopes the commit to the same set, and reports a staged path it did not stage rather than committing or unstaging it (COMMIT-04, 04a, 04b). Restaging the same list is safe for any mix of added, modified, deleted, and renamed paths, because a path already staged in full is skipped — so a staged deletion, or the old half of a rename, cannot make the `git add` fatal for the flows that stage their list twice (COMMIT-04c) — `scripts/lib/stage-paths.sh` (`anchor_stage_paths`, `anchor_other_staged_count`, `anchor_commit_pathspecs`), `scripts/commit-preflight.sh` (`OTHER_STAGED`), `scripts/commit.sh` (`--path`), `skills/commit/SKILL.md` Steps 1/5/6, `tests/{stage-paths,commit-preflight,commit}.test.sh` |
| PREPARE-01..18 (+02a, 03a, 06a, 10a, 10a1, 10b, 13a, 15a) | 26 | All Covered | `prepare-review`, pushed-branch only, reviews the description in the tool, opens the draft CR with the approved body and never before it (PREPARE-03) — `scripts/prepare-review.sh` (`--open`), `skills/prepare-review/SKILL.md` Step 4, `tests/prepare-review.test.sh`. Review-guide links are authored as `anchor:<path>#<token>` placeholders resolved against the changed hunks, an ambiguous or absent token halts with its candidates rather than guessing, and expansion into forge anchors runs once the CR exists and is all-or-nothing (PREPARE-10, 10a, 10b, 15) — `scripts/deep-links.sh` (`--resolve`, `--check`, `--expand`), `guides/cr-formatting.md`, `templates/cr-description.md`, `tests/deep-links.test.sh`. `--verify` stays as the backstop for a hand-built anchor and rejects a malformed line part as well as a mis-numbered one (PREPARE-15a) — `scripts/deep-links.sh` (`part_re`). A `/anchor:<skill>` mention is read as prose rather than as broken placeholder markup, so a description naming the skill that drafted it passes the check (PREPARE-10a1) — `scripts/deep-links.sh` (`stray_anchors`), `tests/deep-links.test.sh`. The token reaches the matcher through the environment rather than an escape-processing `awk -v` assignment, so one carrying a backslash matches byte for byte instead of reporting as an untouched line (PREPARE-10) — `scripts/deep-links.sh` (`resolve`), `tests/deep-links.test.sh`. The review's baseline is always a readable path, an empty file where no CR holds a description, since the review wrapper takes a pair of paths and an empty value is a usage error it never opens past (PREPARE-13a) — `scripts/prepare-review.sh` (`current_desc_path`), `tests/prepare-review.test.sh`. Reports the branch's pipeline once the description lands (PREPARE-16), and names the source branch that won't be deleted on merge, offering the forge's remediation (PREPARE-17) — `skills/prepare-review/SKILL.md`, `scripts/{prepare-review,deep-links,pipeline-after-push}.sh`, `tests/prepare-review.test.sh`. The CR is labelled from the project's own set and given a milestone where one of its open ones fits, added to whatever it already carries (PREPARE-18) — `skills/prepare-review/SKILL.md` Step 4 ("Label it and set the milestone"), `guides/forge-cookbook.md` "Labels and milestones". The default branch with a clean tree and nothing ahead reports `NOTHING_TO_REVIEW=1` and exits 65, so a dead end is an event rather than a key a caller can summarize past (PREPARE-02a) — `scripts/prepare-review.sh`, `tests/prepare-review.test.sh`. A dirty-tree stop reports that changes are uncommitted and nothing more, rather than diagnosing how the tree got that way (PREPARE-06a) — `skills/prepare-review/SKILL.md` "Act on `STATE`". The branch-inferred lookup adopts only an open CR, so a reused branch name whose earlier CR merged or closed gets a fresh draft, and the one passed over is reported as `PRIOR_CR_IID`/`PRIOR_CR_STATE`; an explicit `--cr` still resolves whatever was named (PREPARE-03a) — `scripts/prepare-review.sh` (`resolve_cr`), `skills/prepare-review/SKILL.md` "A reused branch name", `tests/prepare-review.test.sh` |
| REVIEW-01..19 (+03a) | 20 | All Covered | Reviewing a CR — resolve it by number/URL/branch, read the description before the diff, show the whole range in the viewer, place each finding at the narrowest anchor that carries it with the summary as the fallback, gate the post on the exact text, and refuse a post whose head moved (REVIEW-11) — `skills/review/SKILL.md`, `scripts/{review-cr,review-post}.sh`, `guides/forge-cookbook.md`, `tests/review-cr.test.sh`, `tests/review-post.test.sh`. What a review looks for is a template the user edits, read before the diff is examined and weighed one agent per listed quality (REVIEW-15, 16) — `templates/review-qualities.md`, `skills/review/SKILL.md` Step 4. Authorship picks the mode: the user's own CR runs as a self-review whose findings are a working-tree fix list, re-reviewed in a loop and handed off by marking the CR ready through `scripts/mark-ready.sh` and requesting reviewers, with a draft CR expected rather than confirmed (REVIEW-03a, 17, 18) — `skills/review/SKILL.md` Step 5, `guides/forge-cookbook.md` "Mark a CR ready, and request reviewers", `scripts/review-cr.sh` (`IS_OWN_CR`), `tests/review-cr.test.sh`. A self-review finding the author wants on the record still posts through the exact-text and pinned-head gates (REVIEW-19) — `skills/review/SKILL.md` Steps 5-7 |
| FEEDBACK-01..09 | 9 | All Covered | Fetch, triage, act on threads, watch the fix commit's pipeline into the summary (FEEDBACK-09) — `skills/resolve-feedback/SKILL.md`, `scripts/pipeline-after-push.sh` |
| MERGE-01..15 | 15 | All Covered | Gate checks (ready/mergeable/pipeline/approvals/threads), method choice, merge + cleanup — `skills/merge/SKILL.md`, `guides/forge-cookbook.md`. The draft gate clears the flag through `scripts/mark-ready.sh` rather than the CLI directly, so the transition is announced once wherever it is reached (EVENTS-12) |
| RELEASE-01..19 (+03a, 03b, 03c, 04a) | 23 | All Covered | Release-model detection, version recommendation, notes + review, per-model publish — `skills/release/SKILL.md`, `scripts/release-recon.sh`, `guides/release-models.md`, `guides/forge-cookbook.md`. A release workflow triggered only by `workflow_dispatch` reads as CI-owning the bump, gated on a second signal so the manual-run hatch that most workflows carry cannot name a docs deploy as the release workflow, and a `release`/tag trigger alongside it keeps its own model (RELEASE-03a) — `scripts/release-recon.sh` (`workflow_trigger`, `dispatch_publishes`, `detect_ci_model`), `tests/release-recon.test.sh`. The workflow's declared inputs and the one carrying the level are reported so the dispatch passes it by the workflow's own name (RELEASE-03b) — `scripts/release-recon.sh` (`dispatch_inputs`, `bump_input_of`, `RELEASE_DISPATCH_INPUTS`, `RELEASE_DISPATCH_BUMP_INPUT`). A repo that documents its publish path outranks the inference, and one that documents nothing behaves as before (RELEASE-03c) — `scripts/release-recon.sh` (`RELEASE_PUBLISH_DOCS`), `skills/release/SKILL.md` "The repo outranks the inference", `guides/release-models.md`. On that model the notes are committed into the accruing changelog section before the dispatch, so they are reviewed in the commit rather than as a release body, and the dispatch keeps its own confirmation (RELEASE-04a) — `skills/release/SKILL.md` Step 5, `scripts/release-recon.sh` (`RELEASE_NOTES_BASELINE`) |
| ISSUES-01..12 | 12 | All Covered | Author one issue — gather intent, guard duplicates, draft, file (`skills/issue/SKILL.md`). Filing also triages: labels come from the project's own set and a milestone from its open ones, ambiguity goes to the author, an existing issue is only added to, and both ride the body's approval (ISSUES-07..11) — `skills/issue/SKILL.md` Step 5 and Step 6 ("Yes (write)"), `guides/forge-cookbook.md` "Labels and milestones". The approval leads with a link to where the write lands, so the user reads the target before the draft (ISSUES-12) — `skills/issue/SKILL.md` Step 6 |
| BACKLOG-01..06 | 6 | All Covered | Survey what is already filed — scope from the query, rank due-soonest then most-recently-updated, recommend the top pick, write nothing (`skills/backlog/SKILL.md`). GitHub carries no per-issue due date, so the milestone's stands in for it (BACKLOG-04) — `skills/backlog/SKILL.md` Step 3, `guides/forge-cookbook.md` "Issue list" |
| CI-01..14 | 14 | All Covered | Status/watch/job modes, commit-scoped resolution, per-workflow fold and the single-run opt-out; run/job breakdown tabulated with per-state emoji (CI-10..12) and watched once per commit after a push (CI-13..14) — `skills/pipeline/SKILL.md`, `skills/merge/SKILL.md` (CI-09), `templates/pipeline-report.md`, `scripts/{pipeline-status,pipeline-after-push}.sh`, `tests/pipeline-{status,after-push}.test.sh` |
| DIFF-01..30 (+25a) | 30 | 29 Covered, 1 Partial | Tool-agnostic review contract — dispatcher `scripts/review-diff.sh` + adapters `scripts/review/modes/{edit,diff}.sh` + `scripts/review/tools/`; consumers read the normalized verdict, and treat an unparseable or absent one as no-verdict (DIFF-12) — `skills/{commit,prepare-review,issue,release,review}/SKILL.md` verdict sections. `edit` mode edits the artifact rather than commenting on it, reads the save as the verdict — a buffer left unsaved or saved empty aborts, and a save read from the buffer rather than from how the editor left survives the terminal going away afterwards — refuses a review with no artifact, and discounts a no-op `GIT_EDITOR` — continuing past git's own chain to git's compiled default where a terminal can be hosted and a blocking editor on `PATH` where none can, read independent of the ambient terminal and of the no-op values already discounted, so an agent harness holding no configured editor resolves the one a plain `git commit` would open and renders it in the pane anchor labels rather than a window behind the terminal (DIFF-13..16) — `scripts/review/modes/edit.sh` (`emit_review`), `scripts/lib/review-editor.sh` (`anchor_editor_resolve`, `anchor_editor_usable`); the buffer takes the artifact's own extension, so a markdown draft opens with the editor's markdown mode and preview available rather than as plain text (DIFF-13) — `scripts/review/modes/edit.sh` (`editor_buffer_ext`), `tests/review-edit.test.sh`; an editor that saved nothing is named rather than numbered — `unsaved`, `pane-closed`, `no-pane`, `no-host` on `raw.exitCode`, the first two carrying the remedy and treated as re-openable rather than as a rung of the ladder; and where the editor is one anchor knows that returned without its wait flag, the report names that editor and that flag rather than reporting a reviewer who declined to save (DIFF-14) — `scripts/review/modes/edit.sh` (`emit_review`'s cause map, `editor_rc_no_host`), `scripts/lib/editor-flags.sh` (`anchor_editor_wait_flag`, `anchor_editor_blocking`), `scripts/lib/review-host.sh` (`anchor_host_rc_no_result`, `anchor_host_rc_no_pane`), `guides/review-fallback.md` ("Don't retry into the same wall"), `tests/review-edit.test.sh`; the one skill whose subject is always a changeset catches that refusal at the probe rather than launching into it — `skills/review/SKILL.md` Step 3; `--probe` reports the resolved mode and the tool that would run it without launching, plus whether an editor review would reach an editor at all (DIFF-17) — `scripts/review-diff.sh` (`resolve_tool`), `scripts/lib/review-editor.sh` (`anchor_editor_host`, `anchor_editor_available`), `tests/review-edit.test.sh`; availability takes the program and the host together in `diff` as in `edit`, so an installed viewer with no terminal to render it in reports unavailable rather than sending the caller to launch into `no-host` — `scripts/review-diff.sh` (`mode_available`), `tests/review-edit.test.sh`. Resolution runs on two axes: a configured mode is kept so its own report names the missing piece, a subject-picked one gives way only to a mode openable in full — program and host together, so with nowhere to open either the subject's mode is kept and its report names the editor rather than trading it for a viewer — and on the tool axis nothing substitutes, so a viewer the user named is the viewer reported whether or not it is installed (DIFF-11) — `scripts/review-diff.sh` (`usable_mode`, `diff_mode_openable`, `resolved_mode_source`), `tests/review-{diff,edit}.test.sh`. git's difftool is a `diff` tool whose verdict is read from the working tree rather than from the tool: every reviewed file is snapshotted before it opens, each one the reviewer changed comes back carrying the diff of what they wrote, edits are `changes-requested` and an untouched tree is `approved`, and the tool's own exit status is not consulted since `git difftool` drops it (DIFF-18) — `scripts/review/tools/difftool.sh`, `scripts/lib/review-difftool.sh`, `tests/review-difftool.test.sh`. Sorting those edits into fixes to keep and questions to answer-and-remove is the model's, and the removal is verified before the re-review (UX-08) — `guides/reviewer-edits.md`, the `changes-requested` bullets of all five review-consuming skills. An ungraded review takes a fallback ladder rather than a "you saw it, approve?" question — the draft's path, the editor rung where DIFF-17 says it is reachable, and a chat read of the artifact or a file-by-file changeset walk as the floor (DIFF-20) — `guides/review-fallback.md`, the fallback sections of all five review-consuming skills. A git-range review takes caller-supplied header overrides, which is what keeps another author's CR from being labelled with the reviewer's own last commit (DIFF-19) — `scripts/review-diff.sh` (git-range `--title` / `--detail`), `tests/review-cr.test.sh`. An empty resolved range reports `no-verdict` with `raw.exitCode` `empty-range` and launches nothing, since a viewer quit on an empty diff is indistinguishable from an approved review (DIFF-21) — `scripts/review-diff.sh` (empty-range gate), `tests/review-diff.test.sh`. `--local` stages the caller's named paths so a new file reaches the diff, and stops on a path with nothing to stage, rather than sweeping in a co-resident session's work (DIFF-22) — `scripts/review-diff.sh` (`--path`), `scripts/lib/stage-paths.sh` (`anchor_stage_paths`), `tests/review-diff.test.sh`. A re-opened review compares against the draft the reviewer graded rather than the artifact the forge holds, so the second pass shows what the feedback changed (DIFF-23) — the `changes-requested` bullets of `skills/{prepare-review,issue,release}/SKILL.md`. The tool probe runs under the same `--skill` the launch uses, and the consumer names the tool it opens, so a review waiting in a window behind the terminal is not read as a step that never ran (DIFF-24) — the probe blocks of `skills/{prepare-review,issue,release}/SKILL.md`, which name the tool on a defaulted choice as well as a substituted one now that the probe reports which it was. **Partial**: `skills/commit/SKILL.md` does not probe at all, so the tool it opens goes unnamed. A review needing a terminal opens where the calling session can put one — a tmux popup, an iTerm2 split of that session — and the borrowed screen is returned when it closes, so the review cannot rest behind the window the user is watching; one dispatcher answers both the probe and the launch, so they cannot disagree (DIFF-25) — `scripts/lib/review-host.sh` (`anchor_host_available`, `anchor_host_run`), `scripts/lib/review-editor.sh` (`anchor_editor_host`), `tests/review-edit.test.sh`. That host is resolved from one ranked set independent of the mode, so `edit` and `diff` reach equally far; a host serving one mode alone says so rather than getting a selector of its own — the `gui` window answers only `edit` — and the set holds no host the harness could never select, a plugin's scripts being invoked with no controlling terminal (DIFF-25a) — `scripts/lib/review-host.sh` (`anchor_review_hosts`, `anchor_review_host_select`), `scripts/review/hosts/{tmux,gui,iterm2}.sh` (the `gui` window's own availability reading `scripts/lib/editor-flags.sh`), `tests/review-edit.test.sh`. The split carries the directory and the environment the command was resolved against, since a split is not run through a login shell and starts on the terminal's own: a second lookup over there fails on a tool that is installed, and refs resolved against the repo under review draw a different repo's diff from wherever the pane stands (DIFF-26) — `scripts/lib/review-host.sh` (`anchor_host_launch_script`), `tests/review-host.test.sh`. The diff viewer is driven directly rather than through the revdiff plugin's launcher, and an absent viewer, unhostable session, or pane closed before it reported reports `no-verdict` with `raw.exitCode` `absent`, `no-host`, `no-pane`, or `pane-closed` (DIFF-27, DIFF-14) — `scripts/review/modes/diff.sh` (`emit_review`), `scripts/review/tools/revdiff.sh`, `tests/review-diff.test.sh`. An open review is waited on for as long as the reviewer takes, ended early only by the host closing without a result, and never by elapsed time; the result is read once more after the host is seen gone, since quitting the tool writes the status and closes the pane in the same breath and the liveness probe answers for a moment already past (DIFF-28) — `scripts/lib/review-host.sh` (`anchor_host_await`, `anchor_host_read_rc`, `anchor_host_probe_seconds`), `scripts/review/hosts/iterm2.sh` (`iterm2_pane_alive`), `tests/review-host.test.sh`. The split carries the calling session's rendered tab label behind a 👀, attempted rather than required, so the tab the user navigates by keeps its label while the focused review pane holds it and says a review is waiting there (DIFF-29) — `scripts/review/hosts/iterm2.sh` (`review_host_run`'s launch AppleScript). The pane is selected once it is open, since a scripted split is created without being selected and leaves the reviewer typing into the session that is waiting on them (DIFF-30) — `scripts/review/hosts/iterm2.sh` (`select newSession` in the launch AppleScript) |
| CONFIG-01..15 (+15a, 15b) | 17 | All Covered | `anchor.*` key handling, including the per-skill after-push watch gate (CONFIG-06), the review **mode**, which has no key at all — the subject settles it, `edit` where the review is one file with no prior version to compare against and `diff` everywhere else, a git range included since it names a base by construction — and which is still settled against what can actually open rather than assumed present (CONFIG-15 — `scripts/review-diff.sh` (`subject_default_mode`, `resolve_mode`, `usable_mode`), `guides/configuring.md` "A mode per subject", `tests/review-{edit,diff}.test.sh`). What *is* configurable is the tool, one symmetric key per mode: `anchor.edit.tool` over git's chain, `anchor.diff.tool` over git's own `diff.tool` with no viewer assumed past either — an unset pair reports `no-tool` naming the keys rather than selecting revdiff on the user's behalf, since a tool nobody chose returns a verdict recorded as theirs — the superseded single key reported as doing nothing rather than silently obeyed or ignored (CONFIG-15a — `scripts/review-diff.sh` (`resolve_tool`, `report_superseded_key`), `scripts/review/modes/diff.sh` (the `no-tool` gate), `scripts/lib/review-editor.sh` (`anchor_editor_configured`), `guides/configuring.md` "`anchor.diff.tool`", "Where a review opens", `tests/review-edit.test.sh`). The probe is answered from the same subject the launch will carry, and the consumers pass it, so a pre-launch question and the launch cannot name different tools (CONFIG-15b — `scripts/review-diff.sh` (`subject_flag`, `subject_left`), the probe blocks of `skills/{prepare-review,issue,release}/SKILL.md`, `tests/review-edit.test.sh`), and a verbosity dial per artifact — CR (CONFIG-07..10), commit message body (CONFIG-11), issue body (CONFIG-12), release notes (CONFIG-13) — each abbreviating sections rather than removing them, with the cross-artifact invariants, the clamp, and the audience-widens-as-the-default-descends ordering in CONFIG-14 — `guides/configuring.md` (Defaults table), `guides/cr-verbosity.md`, `templates/{cr-description,commit-message,issue-description}.md` ("At lower verbosity"), `scripts/pipeline-after-push.sh` (`config_bool`), commit/prepare-review/issue/release config steps, `tests/config-defaults.test.sh` (the documented defaults agree across SPEC, guide, skills, templates) |
| FORGE-01..09 | 9 | All Covered | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md`; template resolution across the forge's own inheritance with a deterministic per-level pick and the `anchor.crTemplateRepo` backstop (FORGE-06..09) — `scripts/prepare-review.sh`, `tests/prepare-review.test.sh` |
| EVENTS-01..17 | 17 | All Covered | Announcements to sibling plugins — one line per fact the plugin caused, the `codes.bridgeai.anchor/` prefix taken from `name:` so a producer cannot typo its own and cannot announce on a sibling's behalf (EVENTS-01, 02) — `scripts/announce.sh`, `plugin.yml` (`events.publishes`), `tests/announce.test.sh`. The body is built by `jq` rather than interpolated, which is what keeps a value carrying a quote, a backslash, or a newline on one line, and the publisher exits 0 on every path including a missing `jq`, so an announcement cannot turn an operation that succeeded into a tool call that failed (EVENTS-03, 04) — `tests/announce.test.sh` (the round-trip, newline, and no-jq cases). A declared key and the source that emits it have to name each other, which is what keeps a manifest that drives documentation from going stale silently (EVENTS-05) — `tests/announce.test.sh` (the drift trap). A fact a script causes announces from that script, after the operation lands, so a run whose skill stops early still announced the push or the CR (EVENTS-06, 07) — `scripts/prepare-review.sh`, `scripts/commit.sh`, `tests/commit.test.sh`; and `cr.created`/`cr.updated` are exclusive, decided by `CR_CREATED` (EVENTS-08) — `skills/prepare-review/SKILL.md` ("Announce what this run did"). A commit announces after the push, and its address names the project as well as the sha, built from `origin` across the remote shapes a clone can carry and with credentials in that remote dropped rather than announced (EVENTS-09, 10) — `scripts/lib/forge-url.sh`, `tests/forge-url.test.sh`. The draft flag is read at the moment it is cleared and `cr.ready` fires only where it moved, from the one helper both the self-review handoff and the merge gate call (EVENTS-11, 12) — `scripts/mark-ready.sh`, `skills/review/SKILL.md` Step 5, `skills/merge/SKILL.md` gate 1a, `tests/mark-ready.test.sh`. `cr.merged` carries the forge's own merge time and landed sha, read back rather than assembled from what the run knows, and covers the merges anchor performed rather than one the forge completes on its own afterwards (EVENTS-13, 14) — `skills/merge/SKILL.md` Step 3 ("Announce the merge"). `release.created` waits on the forge reporting the release and reads its address and tag back from there, since on the CI-owned models the workflow derives the version; a model that publishes no forge release announces nothing (EVENTS-15, 16) — `skills/release/SKILL.md` Step 6 ("Announce it"). `issue.created` fires on a create only (EVENTS-17) — `skills/issue/SKILL.md` "Yes (write)" |
| RULE-01..05 (+04a) | 6 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md`; RULE-04 routes CR creation through `prepare-review`. The CR-creation URL a push prints is ruled out alongside the bare `create` it stands in for, since it reaches the same web form with the drafting moved onto the user (RULE-04a) — `rules/use-forge-clis.md`, `skills/commit/SKILL.md` Step 6 |
| UX-01..05 (+01a, 06, 06a, 07, 08) | 10 | All Covered | Narration, orchestration, decision prompts, artifact visibility, recon-supplied values — cross-cutting, each `skills/*/SKILL.md`, `guides/execute-quietly.md`. A step that did not complete is reported in terms the user can see rather than in the vocabulary of anchor's own guidance, so a reply names the editor that closed rather than the position the guidance puts it in (UX-01a) — `guides/review-fallback.md` ("Say what happened, not where you are in this guide"). A review launch carries a manifest of what is under review — the files and their counts for a changeset, the artifact and its sections for a drafted document, plus the repo, the branch or CR, and the tool — since the tool draws one file at a time and never shows the set (UX-07) — `guides/execute-quietly.md` ("show what is going under review"), the launch blocks of `skills/{commit,prepare-review,issue,release,review}/SKILL.md`. A mode or a tool anchor settled on rather than the user gets the key that would choose it named in the same message, for that half only, so the hint sits next to what the user didn't pick and retires once they pick one (UX-07) — `scripts/review-diff.sh` (`REVIEW_MODE_SOURCE`, `REVIEW_TOOL_SOURCE`), `scripts/lib/review-editor.sh` (`anchor_editor_source`), `guides/execute-quietly.md` ("when anchor picked the tool"), the probe blocks of `skills/{prepare-review,issue,release}/SKILL.md`, `tests/review-edit.test.sh`. Prescribed commands use a shape and a path the caller can grant, paired with the allow rule that covers them and scoped to a stated set of shells and platforms, while anchor's own scripts stay free to honor `$TMPDIR` (UX-06, 06a) — `guides/temp-paths.md`, `rules/use-forge-clis.md`, `guides/forge-cookbook.md`, `skills/{commit,issue,resolve-feedback}/SKILL.md`, `scripts/lib/tmpfile.sh`, `tests/tmp-path-guidance.test.sh` (ubuntu/macOS/Windows matrix) |
| CONFIRM-01..06 | 6 | All Covered | Approval of the exact text before anything publishes under the user's name — commit message in the review tool (`skills/commit/SKILL.md` Step 5), CR description (`skills/prepare-review/SKILL.md` Steps 4-5), issue body (`skills/issue/SKILL.md`), thread replies (`skills/resolve-feedback/SKILL.md` 3c), release notes (`skills/release/SKILL.md`); CONFIRM-03 is the plan-is-not-prose distinction the reply gate rests on |

## Open / Needs Decision

- **DIFF-24 (Partial)** — the requirement holds in `skills/{prepare-review,issue,release}/SKILL.md`, which name the tool on a defaulted choice as well as a substituted one now that `REVIEW_TOOL_SOURCE` says which it was. `skills/commit/SKILL.md` skips the probe entirely, so the tool it opens still goes unnamed. Extending the rule to it, or narrowing DIFF-24 to the skills that draft a standalone document, is a decision pending.

## Audit history

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
