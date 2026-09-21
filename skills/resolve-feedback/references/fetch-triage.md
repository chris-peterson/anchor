## Step 1: Fetch unresolved feedback

Pull every unresolved, human-authored thread. Canonical invocations live in
the bundled forge cookbook (`<anchor-root>/guides/forge-cookbook.md`, section "List
unresolved review threads"); in short:

- **GitLab** — `glab api "projects/:fullpath/merge_requests/<iid>/discussions?per_page=100"`,
  filtered to non-system discussions with at least one `resolvable` note that
  isn't `resolved`. Keep each discussion's `id`, authors, bodies, and
  `position` (`new_path`, `new_line`) when line-anchored.
- **GitHub** — the GraphQL `reviewThreads` query (REST doesn't expose
  resolution state), filtered to `isResolved: false`. Keep the thread `id`,
  `path`/`line`, and each comment's `databaseId`, author, body.

Also fetch top-level CR comments that ask for changes without anchoring to a
line (GitLab: `notes` with `system == false` not already part of a
discussion; GitHub: `gh pr view --json comments,reviews` review bodies with
`CHANGES_REQUESTED` or non-empty text). Reviewers often put the biggest asks
there.

If there is no unresolved feedback, report that and stop.

## Step 2: Triage with the author

Present every thread in one table, ordered by file/line, each with a
**proposed disposition**:

| # | Where | Reviewer | Ask (summarized) | Proposed |
|---|-------|----------|------------------|----------|
| 1 | `src/deploy.sh:42` | @reviewer | rename flag for clarity | **fix + reply + resolve** |
| 2 | `taskdef.yml:7` | @reviewer | why not Fargate? | **reply only** |

Disposition vocabulary:

- **fix + reply + resolve** — actionable and you agree: change the code,
  reply with what changed and the commit SHA, resolve the thread.
- **fix + reply** — same, but leave resolution to the reviewer (some teams
  reserve resolution for the person who opened the thread — follow the
  project's convention; when unknown, resolving your own addressed threads
  is the common default on GitLab, leaving them open is safer on teams
  you don't know).
- **reply only** — questions, explanations, pushback. Answer on the thread;
  the asker decides whether it's settled. Never resolve a question you
  answered but the asker hasn't acknowledged.
- **defer** — legitimate ask, out of this CR's scope. Reply saying so and
  where it lands (issue link, follow-up CR) — don't leave it unanswered.
- **skip** — leave untouched this round.

Then confirm with the author before acting, using structured choices when the
host supports that (header `Triage`) or asking directly otherwise: **Proceed as
proposed** / **Adjust** (they name the thread numbers and new dispositions) /
**Abort**. This gate settles what happens to each thread; the wording of what
gets said goes to the author separately in 3c, once there are actual sentences
to read.
