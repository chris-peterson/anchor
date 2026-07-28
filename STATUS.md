# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).
Maintained by `/sextant:spec-status`.

**Last audit:** 2026-07-28
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 1.0.1
**Coverage:** 139 Covered, 0 Partial, 0 Missing/Contradicts

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
| TGT-01..09 | 9 | All Covered | Target resolution + worktree isolation — `scripts/{resolve-target,worktree}.sh`, each `skills/*/SKILL.md` "Target repo"; every skill routes a name argument through `resolve-target.sh` |
| CMT-01..20 (16 retired) | 19 | All Covered | Review-first commit-and-push flow (1.0) — `skills/commit/SKILL.md`, `scripts/{commit,commit-preflight,look-ahead,squash-check}.sh` |
| PREP-01..15 | 15 | All Covered | `prepare-review`, pushed-branch only, opens the draft CR without pushing, reviews the description in the tool, verifies deep-link line parts — `skills/prepare-review/SKILL.md`, `scripts/{prepare-review,deep-links}.sh` |
| FDBK-01..08 | 8 | All Covered | Fetch, triage, act on threads — `skills/resolve-feedback/SKILL.md` |
| MRG-01..16 | 16 | All Covered | Gate checks (ready/mergeable/pipeline/approvals/threads), method choice, merge + cleanup — `skills/merge/SKILL.md`, `guides/forge-cookbook.md` |
| REL-01..20 | 20 | All Covered | Release-model detection, version recommendation, notes + review, per-model publish — `skills/release/SKILL.md`, `scripts/release-recon.sh`, `guides/release-models.md`, `guides/forge-cookbook.md` |
| ISS-01..12 | 12 | All Covered | Author one issue — gather intent, guard duplicates, draft, file (`skills/issue/SKILL.md`); list/scope/rank/recommend, read-only (`skills/issues/SKILL.md`) |
| PIPE-01..09 | 9 | All Covered | Status/watch/job modes, commit-scoped resolution, per-workflow fold and the single-run opt-out — `skills/pipeline/SKILL.md`, `skills/merge/SKILL.md` (PIPE-09), `scripts/pipeline-status.sh`, `tests/pipeline-status.test.sh` |
| REV-01..11 | 11 | All Covered | Tool-agnostic review contract — dispatcher `scripts/review-diff.sh` + adapters `scripts/review/{moor,revdiff}.sh`; consumers read the normalized verdict |
| CONF-01..05 | 5 | All Covered | `anchor.*` key handling — `guides/configuring.md`, commit/prepare-review/issue config steps |
| FORG-01..05 | 5 | All Covered | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md` |
| RULE-01..05 | 5 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md`; RULE-04 routes CR creation through `prepare-review` |
| UX-01..05 | 5 | All Covered | Narration, orchestration, decision prompts, artifact visibility, recon-supplied values — cross-cutting, each `skills/*/SKILL.md`, `guides/execute-quietly.md` |

## Audit history

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
rather than amending a committed checkpoint. The `--preview` mode is retired
(CMT-16 removed). `prepare-review` keeps its name but is reworked to operate only
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
