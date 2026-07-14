# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).
Maintained by `/sextant:spec-status`.

**Last audit:** 2026-07-14
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 1.0.0
**Coverage:** 90 Covered, 0 Partial, 0 Missing/Contradicts

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
| TGT-01..09 | 9 | All Covered | Target resolution + worktree isolation — `scripts/{resolve-target,worktree}.sh`, each `skills/*/SKILL.md` "Target repo" |
| CMT-01..19 (16 retired) | 18 | All Covered | Review-first commit-and-push flow (1.0) — `skills/commit/SKILL.md`, `scripts/{look-ahead,squash-check}.sh` |
| CRR-01..13 | 13 | All Covered | `create-review` (formerly `prepare-review`), pushed-branch only, opens the draft CR without pushing — `skills/create-review/SKILL.md`, `scripts/create-review.sh` |
| FDBK-01..08 | 8 | All Covered | Fetch, triage, act on threads — `skills/resolve-feedback/SKILL.md` |
| ISS-01..12 | 12 | All Covered | Author one issue — gather intent, guard duplicates, draft, file (`skills/issue/SKILL.md`); list/scope/rank/recommend, read-only (`skills/issues/SKILL.md`) |
| PIPE-01..06 | 6 | All Covered | Status/watch/job modes — `skills/pipeline/SKILL.md`, `scripts/pipeline-status.sh` |
| RVEW-01..06 | 6 | All Covered | Sidecar verdict contract + graceful degrade — `scripts/review-diff.sh`, each skill's review step |
| CONF-01..05 | 5 | All Covered | `anchor.*` key handling — `guides/configuring.md`, commit/create-review/issue config steps |
| FORG-01..05 | 5 | All Covered | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md` |
| RULE-01..05 | 5 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md`; RULE-04 routes CR creation through `create-review` |
| UX-01..03 | 3 | All Covered | Narration, orchestration, decision prompts — cross-cutting, each `skills/*/SKILL.md` |

## Audit history

### 2026-07-14 — 1.0 commit/review redesign (spec ahead of implementation)

Reworked the commit and review-request flow toward a 1.0 release. `/anchor:commit`
becomes review-first and commit-and-push: it reviews the pending changeset (working
tree vs `HEAD`) before committing, then commits and pushes in one step (CMT-14/15
rewritten, CMT-18/19 added); fix-now now edits the working tree and re-reviews
rather than amending a committed checkpoint. The `--preview` mode is retired
(CMT-16 removed). `prepare-review` is renamed `create-review` and operates
only on an already-pushed branch — it opens the draft CR but never pushes and
imposes no review gate (the pre-push review gate PREP-03/04 is retired); the
category is renumbered PREP → CRR-01..13. RULE-04 and the Skill concept updated to
the new name.

The implementation landed on the `1.0` branch in the same pass: `/anchor:commit`
reviews then commits-and-pushes, `--preview` is gone, and the skill and script are
renamed to `create-review`, so the CMT, CRR, and RULE rows are Covered
again. 90 requirements across 11 categories; version bumped to 1.0.0.

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
