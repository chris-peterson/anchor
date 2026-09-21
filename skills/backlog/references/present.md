## Step 4: Present and recommend

Print a compact table — most-actionable at the top — with the columns that drove the ranking, so the order is self-explaining:

- **#** (number), **Title**, **Due** (the date, or `—` when none), **Updated** (relative, e.g. `2d ago`), and **Labels** only if any are set.
- State column only when the scope includes more than open (e.g. "closed too").
- Lead the table with a one-line scope summary: `Assigned to you · open · ranked by due ↑ then updated ↓`.

Then **recommend the next pick**: name the top-ranked issue and give the one-line reason it's first (soonest due, or most recently active when nothing is dated). Offer to open it — this skill stops at reading, so "open" means show its detail or the browser, not start work:

```bash
# GitHub — detail in the terminal, or open in the browser
gh issue view <number>
gh issue view <number> --web
```

```bash
# GitLab
glab issue view <iid>
glab issue view <iid> --web
```

If the list is empty, say so plainly (e.g. "No open issues assigned to you") and suggest the obvious widening ("want the whole open backlog?") rather than presenting an empty table.

On a 401/403 or other auth failure, surface it and ask the user to refresh credentials — don't retry or silently degrade (per the fail-fast-on-auth rule).
