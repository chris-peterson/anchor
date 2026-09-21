---
name: backlog
description: List and rank the forge issues assigned to you so you can pick what to work on next — ranked by soonest due date, then most recently updated. Use whenever finding, browsing, surveying, or choosing the next issue/ticket to pick up, even when the user doesn't say "backlog" — e.g. "what's next?", "what should I work on?", "anything due soon?", "show my open issues", "show my open tickets". For filing or updating a single issue, use the `issue` skill instead.
---

# Backlog

Before using a bundled path, resolve `<anchor-root>` to the installed plugin root
from the host's value or this `SKILL.md` path. Read and follow
`<anchor-root>/guides/host-runtime.md`, including its instruction-reading rules.
Resolve the relative links below against this skill's directory.

The phase files are required instructions, not optional background. Before
executing a phase, read every file named for it in full; then follow its steps.
Read only the applicable phases, in order, and follow their stop conditions and
return paths. If a required read is missing or truncated, finish the read before
acting; never substitute this entry point's summary for the procedure. Retain
the resolved target and prior helper results across phases. After compaction,
re-read the current phase and recover those results before continuing.

List and rank the user's forge issues, then recommend what to work on next.
Default to open issues assigned to the user; change scope only when requested.
This flow reads issues and opens a chosen issue for inspection; it does not
change their state or start implementing a recommendation.

## Required phases

1. **Resolve scope:** read [scope](references/scope.md) before resolving the
   target and translating the query into filters. Clarify ambiguous scope.
2. **Fetch and rank:** read [fetch and rank](references/fetch-rank.md). Preserve
   the forge-specific due-date and ordering behavior; do not invent dates.
3. **Present:** read [presentation](references/present.md). Show the ranked list
   and recommendation, then inspect a pick only if requested. Surface auth
   failures instead of silently returning a reduced backlog.
