## Step 2: Fetch

Fetch as JSON so Step 3 can rank client-side — the compound sort (due, then updated) is more than either CLI does in one `--sort`, so let the CLI filter and the ranking happen locally. Cap the fetch (`--limit` / `--per-page`) at a browseable size; the goal is "what's next," not the entire history.

```bash
# GitHub — default view (assigned to me, open)
gh issue list --assignee "@me" --state open --limit 50 \
  --json number,title,url,state,updatedAt,createdAt,milestone,labels,assignees
```

```bash
# GitLab — default view (assigned to me, open — glab lists open by default;
# --closed or --all widen it)
glab issue list --assignee=@me --output json --per-page 50
```

Adjust the filter flags per Step 1: GitHub uses `--search "no:assignee"` for unassigned, `--label <name>`, `--state all`; GitLab uses `--label <name>`, `--all` (open + closed), `--author`/`--assignee <username>`. The full flag set and known gaps are in the forge cookbook (`<anchor-root>/guides/forge-cookbook.md`).

## Step 3: Rank

Rank by **due date ascending (soonest first), then updated-at descending (most recently active first)**. Issues with no due date sort *after* all dated ones, and among themselves fall back to most-recently-updated — so the backlog you actually touch stays near the top even when nothing carries a due date.

A stable sort composes the two keys cleanly: sort by the secondary key first, then by the primary. A missing due date maps to a far-future sentinel so it lands last:

```bash
# GitHub — due is the milestone's due date (issues have no per-issue due date)
jq 'sort_by(.updatedAt) | reverse | sort_by(.milestone.dueOn // "9999-12-31")'
```

```bash
# GitLab — issues carry a native due_date
jq 'sort_by(.updated_at) | reverse | sort_by(.due_date // "9999-12-31")'
```

> **Why GitHub uses the milestone due date:** GitHub issues have no due-date field of their own — only milestones carry `dueOn`. So an issue's "due" is its milestone's due date when it has one, and absent otherwise. GitLab issues have a real `due_date`, so it's used directly. Call out this difference only if the user asks why a GitHub list looks undated.
