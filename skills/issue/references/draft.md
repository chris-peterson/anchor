## Step 4: Draft the issue

### Honor an existing forge template

Before drafting, check whether the project ships an issue template. This reads the repo's files, so it needs a **local checkout** — look under `TARGET_LOCAL` when a target resolved one (`ls <TARGET_LOCAL>/.gitlab/issue_templates/*.md`). When the target is remote-only (`TARGET_LOCAL` empty), skip template detection and note that a project template, if the repo has one, wasn't applied — don't block the issue on a checkout you don't have.

- **GitLab:** `.gitlab/issue_templates/*.md` (respect the configured default if more than one)
- **GitHub:** `.github/ISSUE_TEMPLATE/*.md`, or the legacy `.github/ISSUE_TEMPLATE.md`. A `.yml` **issue form** is a structured format — don't compose prose into it; surface it and let the author fill it in the web UI.

If a template exists, it's the team's required scaffolding — **compose into it, don't replace it.** Fill the sections it defines, preserve its checklists and headings verbatim, and **strip any "delete before publishing" instruction block** after following its guidance. On a structure conflict the team template wins. The composition rules live in the "Honoring a project's forge template" section of `<anchor-root>/templates/issue-description.md`.

### Honor `anchor.*` config

Read the project + global `anchor.*` keys once:

```bash
git config --get-regexp '^anchor\.' 2>/dev/null
```

`--get-regexp` returns the names lowercased (`anchor.issuerules`); match them case-insensitively. Apply the keys relevant to an issue; absent keys keep `anchor`'s defaults — never invent a value:

- **`anchor.workTrackerBaseUri`** — when the author mentions a ticket (a full tracker URL, or a bare id), link it in the Context section: use a full URL as-is, or build `<base-uri><id>` from a bare id. No mention, no link.
- **`anchor.issueRules`** — an extra standing rule layered onto every issue (the escape hatch for anything without a dedicated key).
- **`anchor.issueVerbosity`** — an integer 1–100 setting where the issue body sits between brevity and thoroughness. **Unset behaves as `75`** — the highest of `anchor`'s four verbosity defaults, which descend as the audience widens (issue `75` → commit `50` → CR `25` → release `10`). An issue's audience is the few people who'll do the work, and background that would pad a release note saves them a conversation here. **It is not a word budget** — nothing is counted or truncated. Clamp an out-of-range or non-integer value into the 1–100 band and say so once rather than failing the draft.

  **It abbreviates sections; it never removes one.** Which sections an issue has is the template's call — `anchor`'s own shape, or the team's when the project ships one — and a section that earns its place is present at every setting. Work down this order and stop where the draft balances where the setting asks: callouts and asides → the Proposed approach's explanation, down to its load-bearing decisions → Considerations, down to one sentence per concern → Context's second paragraph, then the first down to its *why* sentence. **Acceptance criteria are never abbreviated at any setting**: they state what done means, so they're the issue's floor the way deep links are a CR description's. A low setting buys fewer words, not louder ones.

`anchor.reviewBudgetMins` does not apply to issues. See `<anchor-root>/guides/configuring.md` for the full key set.

### Body structure

Draft a concise imperative **title** (under 72 characters), then the body following the section template in `<anchor-root>/templates/issue-description.md`: **Context**, **Proposed approach**, **Acceptance criteria**, and **Considerations** *(optional)*. The template owns the *shape*; the discipline below owns the *technique*.

- **Lead with why, write for the unfamiliar reader** — the same ELI5 audience assumption `prepare-review` uses. Establish the system/business context in a sentence or two before the detail.
- **Keep the approach about the plan, not the code** — what's being built and why the load-bearing decisions were made, not how every class is wired.
- **Define unfamiliar terms with short callouts** (`> **Term?** …`), sparingly and only where a newcomer would be lost.
- **Diagram only when it carries shape prose hides** — `anchor`'s mermaid conventions (hand-drawn look, no `\n`/`<br>` in labels).
- **Same "what to avoid" discipline as a CR description** — no loaded framing (`<anchor-root>/guides/loaded-framing.md`), no drift artifacts, no leaked deliberation, nothing the reader can already see.
- **Watch the rendering gotchas** — the body is pasted into a markdown renderer; the bundled `<anchor-root>/guides/markdown-gotchas.md` lists the traps (character escaping, nested fences, mermaid, `<details>`, tables in lists).
