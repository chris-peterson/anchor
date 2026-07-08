# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).
Maintained by `/sextant:spec-status`.

**Last audit:** 2026-07-08
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 0.20.0
**Coverage:** 85 Covered, 0 Partial, 0 Missing/Contradicts

The implementation is the plugin itself — the five skill prompts under
`skills/`, the ambient rules under `rules/`, and the helper scripts under
`scripts/`. These requirements were reverse-engineered from that documented
behavior via `/sextant:spec-req init from implementation`, so each is Covered by
the source it was derived from. Treat coverage as a draft to review against the
implementation, not an audited ledger.

## Status by category

| Prefix | Count | Status | Notes |
|--------|------:|--------|-------|
| TRGT-01..09 | 9 | All Covered | Target resolution + worktree isolation — `scripts/{resolve-target,worktree}.sh`, each `skills/*/SKILL.md` "Target repo" |
| CMMT-01..17 | 17 | All Covered | Test/stage/message/squash/preview flow — `skills/commit/SKILL.md`, `scripts/{look-ahead,squash-check}.sh` |
| PREP-01..15 | 15 | All Covered | Gather, review gate, rebase, draft — `skills/prepare-review/SKILL.md`, `scripts/prepare-review.sh` |
| FDBK-01..08 | 8 | All Covered | Fetch, triage, act on threads — `skills/resolve-feedback/SKILL.md` |
| ISSU-01..06 | 6 | All Covered | Gather intent, dedupe, draft, file — `skills/issue/SKILL.md` |
| PIPE-01..06 | 6 | All Covered | Status/watch/job modes — `skills/pipeline/SKILL.md`, `scripts/pipeline-status.sh` |
| RVEW-01..06 | 6 | All Covered | Sidecar verdict contract + graceful degrade — `scripts/review-diff.sh`, each skill's review step |
| CONF-01..05 | 5 | All Covered | `anchor.*` key handling — `guides/configuring.md`, commit/prepare-review/issue config steps |
| FORG-01..05 | 5 | All Covered | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md` |
| AMBR-01..05 | 5 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md` |
| INTX-01..03 | 3 | All Covered | Narration, orchestration, decision prompts — cross-cutting, each `skills/*/SKILL.md` |

## Audit history

### 2026-07-08 — Initial extraction

Spec bootstrapped from the implementation via
`/sextant:spec-req init from implementation`. 85 requirements across 11
categories, all Covered by the skill / rule / script they were derived from.

## How to use this file

When you implement a new requirement, change the row's status and add an
evidence pointer. When an audit reveals drift, update the row to **Partial**
or **Contradicts** with a one-line note.
