# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).
Maintained by `/sextant:spec-status`.

**Last audit:** 2026-08-13
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 1.5.0
**Coverage:** 193 Covered, 0 Partial, 0 Missing/Contradicts

The implementation is the plugin itself — the skill prompts under
`skills/`, the ambient rules under `rules/`, and the helper scripts under
`scripts/`. These requirements were reverse-engineered from that documented
behavior via `/sextant:spec-req init from implementation`, and the 1.0
commit/review redesign (see audit history) has since landed in the source, so
each is Covered by the skill / rule / script it maps to. Treat coverage as a
draft to review against the implementation, not an audited ledger.

## Status by category

| Prefix | Count | Status | Notes |
|--------|------:|--------|-------|
| TARGET-01..09 | 9 | All Covered | Target resolution + worktree isolation — `scripts/{resolve-target,worktree}.sh`, each `skills/*/SKILL.md` "Target repo"; every skill routes a name argument through `resolve-target.sh` |
| COMMIT-01..22 | 22 | All Covered | Review-first commit-and-push flow (1.0), recon before tests, pipeline watch after the push (COMMIT-21), and the direct-to-default choice described as landing without a CR rather than as bypassing review (COMMIT-22) — `skills/commit/SKILL.md`, `scripts/{commit,commit-preflight,look-ahead,squash-check,pipeline-after-push}.sh` |
| PREPARE-01..17 | 17 | All Covered | `prepare-review`, pushed-branch only, opens the draft CR without pushing, reviews the description in the tool, verifies deep-link line parts, reports the branch's pipeline once the description lands (PREPARE-16), and names the source branch that won't be deleted on merge, offering the forge's remediation (PREPARE-17) — `skills/prepare-review/SKILL.md`, `scripts/{prepare-review,deep-links,pipeline-after-push}.sh`, `tests/prepare-review.test.sh` |
| REVIEW-01..14 | 14 | All Covered | The reviewer's side — resolve a CR by number/URL/branch, read the description before the diff, show the whole range in the viewer, anchor findings to lines with the summary as the fallback, gate the post on the exact text, and refuse a post whose head moved (REVIEW-11) — `skills/review/SKILL.md`, `scripts/{review-cr,review-post}.sh`, `templates/cr-review.md`, `guides/forge-cookbook.md`, `tests/review-cr.test.sh`, `tests/review-post.test.sh` |
| FEEDBACK-01..09 | 9 | All Covered | Fetch, triage, act on threads, watch the fix commit's pipeline into the summary (FEEDBACK-09) — `skills/resolve-feedback/SKILL.md`, `scripts/pipeline-after-push.sh` |
| MERGE-01..16 | 16 | All Covered | Gate checks (ready/mergeable/pipeline/approvals/threads), method choice, merge + cleanup — `skills/merge/SKILL.md`, `guides/forge-cookbook.md` |
| RELEASE-01..20 | 20 | All Covered | Release-model detection, version recommendation, notes + review, per-model publish — `skills/release/SKILL.md`, `scripts/release-recon.sh`, `guides/release-models.md`, `guides/forge-cookbook.md` |
| ISSUES-01..12 | 12 | All Covered | Author one issue — gather intent, guard duplicates, draft, file (`skills/issue/SKILL.md`); list/scope/rank/recommend, read-only (`skills/issues/SKILL.md`) |
| CI-01..14 | 14 | All Covered | Status/watch/job modes, commit-scoped resolution, per-workflow fold and the single-run opt-out; run/job breakdown tabulated with per-state emoji (CI-10..12) and watched once per commit after a push (CI-13..14) — `skills/pipeline/SKILL.md`, `skills/merge/SKILL.md` (CI-09), `templates/pipeline-report.md`, `scripts/{pipeline-status,pipeline-after-push}.sh`, `tests/pipeline-{status,after-push}.test.sh` |
| DIFF-01..20 | 20 | All Covered | Tool-agnostic review contract — dispatcher `scripts/review-diff.sh` + adapters `scripts/review/{moor,revdiff,editor,git}.sh`; consumers read the normalized verdict, and treat an unparseable or absent one as no-verdict (DIFF-12) — `skills/{commit,prepare-review,issue,release,review}/SKILL.md` verdict sections. The editor backend edits the artifact rather than commenting on it, aborts on an emptied buffer, refuses a review with no artifact, and discounts a no-op `GIT_EDITOR` (DIFF-13..16) — `scripts/review/editor.sh` (`emit_review`), `scripts/lib/review-editor.sh` (`anchor_editor_resolve`); the one skill whose subject is always a changeset catches that refusal at the probe rather than launching into it — `skills/review/SKILL.md` Step 3; `--print-backend` reports the resolved backend without launching, plus whether an editor review would reach an editor at all (DIFF-17) — `scripts/review-diff.sh` (`resolve_backend`), `scripts/lib/review-editor.sh` (`anchor_editor_host`, `anchor_editor_available`), `tests/review-editor.test.sh`. Resolution considers only installed tools, substituting an installed viewer for an absent one and otherwise keeping the configured backend so its report names the missing tool, with `editor` and `git` both selectable but never substituted in (DIFF-11) — `scripts/review-diff.sh` (`installed_backend`), `tests/review-diff.test.sh`. git's difftool is not a selectable backend at all, so asking for it fails as an unknown name (DIFF-18) — `scripts/review-diff.sh`, `tests/review-diff.test.sh`. It still reaches the screen as moor's transport, and that ungraded result is the DIFF-10 shape — `scripts/lib/review-difftool.sh`, `scripts/review/moor.sh`. An ungraded review takes a fallback ladder rather than a "you saw it, approve?" question — the draft's path, the editor rung where DIFF-17 says it is reachable, and a chat read of the artifact or a file-by-file changeset walk as the floor (DIFF-20) — `guides/review-fallback.md`, the fallback sections of all five review-consuming skills. A git-range review takes caller-supplied header overrides, which is what keeps another author's CR from being labelled with the reviewer's own last commit (DIFF-19) — `scripts/review-diff.sh` (git-range `--title` / `--detail`), `tests/review-cr.test.sh` |
| CONFIG-01..15 | 15 | All Covered | `anchor.*` key handling, including the per-skill after-push watch gate (CONFIG-06), the per-skill review backend, whose preference is settled against what is installed rather than assumed present (CONFIG-15 — `scripts/review-diff.sh` (`resolve_backend`, `installed_backend`), `guides/configuring.md` "A backend per artifact", `tests/review-{editor,diff}.test.sh`), and a verbosity dial per artifact — CR (CONFIG-07..10), commit message body (CONFIG-11), issue body (CONFIG-12), release notes (CONFIG-13) — each abbreviating sections rather than removing them, with the cross-artifact invariants, the clamp, and the audience-widens-as-the-default-descends ordering in CONFIG-14 — `guides/configuring.md` (Defaults table), `guides/cr-verbosity.md`, `templates/{cr-description,commit-message,issue-description}.md` ("At lower verbosity"), `scripts/pipeline-after-push.sh` (`config_bool`), commit/prepare-review/issue/release config steps, `tests/config-defaults.test.sh` (the documented defaults agree across SPEC, guide, skills, templates) |
| FORGE-01..09 | 9 | All Covered | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md`; template resolution across the forge's own inheritance with a deterministic per-level pick and the `anchor.crTemplateRepo` backstop (FORGE-06..09) — `scripts/prepare-review.sh`, `tests/prepare-review.test.sh` |
| RULE-01..05 | 5 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md`; RULE-04 routes CR creation through `prepare-review` |
| UX-01..05 | 5 | All Covered | Narration, orchestration, decision prompts, artifact visibility, recon-supplied values — cross-cutting, each `skills/*/SKILL.md`, `guides/execute-quietly.md` |
| CONFIRM-01..06 | 6 | All Covered | Approval of the exact text before anything publishes under the user's name — commit message in the review tool (`skills/commit/SKILL.md` Step 5), CR description (`skills/prepare-review/SKILL.md` Steps 4-5), issue body (`skills/issue/SKILL.md`), thread replies (`skills/resolve-feedback/SKILL.md` 3c), release notes (`skills/release/SKILL.md`); CONFIRM-03 is the plan-is-not-prose distinction the reply gate rests on |

## Audit history

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

`tests/review-editor.test.sh` was passing by coincidence of the environment: its
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
