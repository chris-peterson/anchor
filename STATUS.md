# anchor — Spec Coverage Status

Tracking status of the requirements declared in [`SPEC.md`](SPEC.md).
Maintained by `/sextant:spec-status`.

**Last audit:** 2026-07-08
**Spec version:** root SPEC.md (unversioned)
**Plugin version:** 0.24.0
**Coverage:** 107 Covered, 0 Partial, 0 Missing/Contradicts

The implementation is the plugin itself — the skill prompts under
`skills/`, the ambient rules under `rules/`, and the helper scripts under
`scripts/`. These requirements were reverse-engineered from that documented
behavior via `/sextant:spec-req init from implementation`, so each is Covered by
the source it was derived from. Treat coverage as a draft to review against the
implementation, not an audited ledger.

## Status by category

| Prefix | Count | Status | Notes |
|--------|------:|--------|-------|
| TGT-01..09 | 9 | All Covered | Target resolution + worktree isolation — `scripts/{resolve-target,worktree}.sh`, each `skills/*/SKILL.md` "Target repo" |
| CMT-01..17 | 17 | All Covered | Test/stage/message/squash/preview flow — `skills/commit/SKILL.md`, `scripts/{look-ahead,squash-check}.sh` |
| PREP-01..15 | 15 | All Covered | Gather, review gate, rebase, draft — `skills/prepare-review/SKILL.md`, `scripts/prepare-review.sh` |
| FDBK-01..08 | 8 | All Covered | Fetch, triage, act on threads — `skills/resolve-feedback/SKILL.md` |
| MRG-01..16 | 16 | All Covered | Gate checks (ready/mergeable/pipeline/approvals/threads), method choice, merge + cleanup — `skills/merge/SKILL.md`, `guides/forge-cookbook.md` |
| ISS-01..12 | 12 | All Covered | Author one issue — gather intent, guard duplicates, draft, file (`skills/issue/SKILL.md`); list/scope/rank/recommend, read-only (`skills/issues/SKILL.md`) |
| PIPE-01..06 | 6 | All Covered | Status/watch/job modes — `skills/pipeline/SKILL.md`, `scripts/pipeline-status.sh` |
| RVEW-01..06 | 6 | All Covered | Sidecar verdict contract + graceful degrade — `scripts/review-diff.sh`, each skill's review step |
| CONF-01..05 | 5 | All Covered | `anchor.*` key handling — `guides/configuring.md`, commit/prepare-review/issue config steps |
| FORG-01..05 | 5 | All Covered | Template composition, body-file, markdown, auth — `templates/`, `guides/{forge-cookbook,markdown-gotchas}.md` |
| RULE-01..05 | 5 | All Covered | SessionStart-injected rules — `hooks/emit-rules.sh`, `rules/*.md` |
| UX-01..03 | 3 | All Covered | Narration, orchestration, decision prompts — cross-cutting, each `skills/*/SKILL.md` |

## Audit history

### 2026-07-17 — Merge skill added

Added the `merge` skill (`MRG-01..16`) — the terminal lifecycle step that lands an
approved CR: checks the ready/mergeable/pipeline/approvals/threads gates (waiting on
the pipeline via `pipeline-status.sh --watch`), merges with a commit-preserving merge
commit (`--no-ff`) unless the project/CR is configured otherwise, via `gh`/`glab`, then returns to the default
branch and deletes the merged branch. Canonical merge/approval/mergeable invocations
added to `guides/forge-cookbook.md`. Requirement rows added by hand alongside the code
change; run `/sextant:spec-status` for a full re-audit. 107 requirements across 12
categories.

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
