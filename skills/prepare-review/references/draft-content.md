### Anti-recency-bias check (do this *before* drafting Context)

Recency bias is the dominant failure mode here: detail you spent the last hour polishing carries disproportionate weight in working memory and anchors the Context section even when the CR is about something much larger. **The headline is what the *branch* was for — usually the first commit, not the last.** Mechanical fix:

1. **List the 3-5 things you most recently iterated on** (in this session, or in the last few commits). Be concrete: "polished two chip labels", "rewrote cache-key construction".
2. **Write a disposition for each** against *would a fresh reviewer consider this central?* — **Centerpiece** (lead Context), **Footnote** (one bullet in Review guide), or **Cut**.
3. **If everything came out "centerpiece", redo it.** Follow-up commits are footnotes. If a follow-up deserves co-headline status, it's actually a separate CR.

Run this check **internally** — the disposition list is scratch that shapes the draft, not output. The only thing the user sees from this step is the resulting draft (see **Execute quietly** at the top).

### Title

A concise imperative phrase (under 72 characters) that captures the change. Same rules as a good commit subject line.

### Body structure

Draft the description following the section template in `<anchor-root>/templates/cr-description.md`: **Context**, **Review guide**, **Approach & trade-offs** *(rare)*, **Testing** *(rare)*, and **Validation** *(when correctness is best shown by real-world use)*. The template owns the *shape*; the guidance below owns the *technique* for realizing it.

**Use these heading names verbatim** — Context / Review guide / Approach & trade-offs / Testing / Validation are canonical, not paraphrasable; reviewers scan for them. Omit a section that doesn't apply; never rename one. (The template spells out why.)

**Ordering dependency (when Step 2 captured one).** Near the top of Context, add a bare, autolinking reference — `Depends on !<iid>` (GitLab) / `Depends on #<num>` (GitHub) — and a line that it must merge first. On GitHub, and on any GitLab fall-back (see Step 4), this prose is the *only* ordering signal, so say plainly that the forge won't enforce it.

**Deep-link construction (Review guide).** Always deep-link to the actual line, not just the file — reviewers should be one click away from the change. **Write a placeholder, not a URL:** `` [`<path>`](anchor:<path>#<token>) ``, where the token is a distinctive literal substring of the line you're pointing at (an identifier, a flag, a heading's text). Use the angle-bracket form — `` [`<path>`](<anchor:<path>#<token>>) `` — when the token carries spaces or parentheses, and drop the `#<token>` for a file-level link. Step 4 resolves each token to its line and writes the forge URL in.

**Never write a line number, and never build an anchor.** A hand-read number still resolves — the forge scrolls to *a* line, just not the one your bullet describes — and nothing about the rendered link reveals it. The full form, and what to do when a token comes back ambiguous, is in `<anchor-root>/guides/cr-formatting.md`.

**Pipeline artifacts — fetch, reason, include.** When the CR or its commit's pipeline produces an artifact that bears on review, fetch it, reason about what it shows, and include the pertinent excerpt (collapsed if long; see `<anchor-root>/guides/cr-formatting.md`). Don't describe a change whose effect the pipeline already rendered without showing it.

**Validation — ask, don't guess.** The Validation section records *evidence* of real-world use, and applies only when the diff plus the rendered artifact don't settle correctness on their own — a shared component consumed by other repos, or a tool/automation whose value is the work it drives. When those signals fire, ask the author what validation looks like rather than guessing a checklist row; skip the section entirely when the diff plus CI already settle it. The detection signals, the prompt, and the evidence-row format live in the template's Validation section (`<anchor-root>/templates/cr-description.md`).

### Tone

Conversational and informal. Reviewers are colleagues, not stakeholders — write like you'd talk through the change at a desk, not like a status report. Sentence fragments are fine. Mid-thought asides in parens are fine. Don't sweat capitalization on tier labels and short bullets, and don't sweat trailing punctuation on fragments — `core change, lives here` reads as well as `Core change, lives here.` and a closing period on a one-line bullet adds nothing. Save the more formal register for the *Why* paragraph where context actually matters; everywhere else, default low-friction.

**Neither length knob is license for marketing punch.** A low `anchor.reviewBudgetMins` (≈5) steers *what you include* and a low `anchor.crVerbosity` steers *how much prose it gets*; neither loosens the register into hype. Short prose is where a tagline is most tempting and least affordable — at `crVerbosity 1` the few words left are all a reviewer gets, so every one of them has to be a fact. Buzzwords, reviewer flattery ("you know this system cold"), and punchy taglines cost attention without earning it. Terse means *fewer words*, not *louder ones*; the no-hyperbole discipline in "What to avoid" governs at every budget.

### Formatting

**Presentation is a primary concern, not a finishing pass.** Before drafting, ask: *what shape is this data, and what visualization fits it?* — then pick deliberately; a diagram that doesn't match the data shape is worse than none. The full technique lives in the bundled `<anchor-root>/guides/cr-formatting.md`: the data-shape → visualization menu, the prose bold/italic/backtick conventions (with the forge-autolink bare-token exception), collapsible `<details>`, mermaid diagram and before/after recipes, and the screenshot-capture workflow. Consult it while drafting. The render-time traps that break any forge markdown — character escaping, nested fences, mermaid-fence placement, the `<details>` blank-line rule — stay in `<anchor-root>/guides/markdown-gotchas.md`.
