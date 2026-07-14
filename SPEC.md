# anchor — Specification

anchor is a set of Claude Code skills and ambient rules that carry
work-in-progress through review and into source control — committing with
why-first messages, opening and describing change requests, resolving review
feedback, filing issues, and reporting pipelines — consistently across GitHub
and GitLab.

Requirements use [EARS syntax](https://alistairmavin.com/ears) — each is one of:
Ubiquitous (`The <system> shall …`), State-Driven (`While …`), Event-Driven
(`When …`), Optional (`Where …`), or Unwanted Behaviour (`If … then …`).

These requirements were reverse-engineered from the implementation (the skill
prompts under `skills/`, the ambient rules under `rules/`, and the helper
scripts under `scripts/`). They are a derived description of documented
behavior, not an independent authority — review them against the source.

## Concepts

- **Skill** — a user-invocable command the plugin exposes: `/anchor:commit`,
  `/anchor:create-review-request`, `/anchor:resolve-feedback`, `/anchor:issue`,
  `/anchor:pipeline`.
- **Forge** — GitHub or GitLab, selected by the `origin` remote; drives the CLI
  choice (`gh` for GitHub, `glab` for GitLab).
- **CR (change request)** — a pull request on GitHub or a merge request on
  GitLab.
- **Default branch** — the repo's integration branch (`main`/`master`),
  resolved from `origin/HEAD`.
- **Ambient rule** — standing guidance a `SessionStart` hook injects into every
  session's context.
- **Review sidecar / verdict** — the `review-diff.sh` wrapper's contract: it
  drives the configured difftool (moor when present) through a `MOOR_CONTEXT`
  file and returns a normalized verdict (`0` clean · `1` fix-now · `2`
  unreviewed · `3` closed-early · `absent` no-verdict).
- **Squash gate** — the deterministic "is HEAD out for review?" decision
  (`squash-check.sh`) that governs squash-vs-new-commit.
- **Deep link** — a line-anchored forge URL in a CR description that lands a
  reviewer directly on the relevant hunk.
- **Worktree isolation** — running a write flow that targets a non-cwd repo in a
  dedicated git worktree, set up and torn down around the flow.
- **tack** / **moor** — sibling plugins anchor integrates with when present
  (repo resolution; visual diff review). Each is optional and degrades
  gracefully when absent.

## Requirements

### TGT — Target repo resolution

- **[TGT-01]** When a skill is invoked with a name argument, the system shall
  resolve that name through tack's repo db before operating on any repo.
- **[TGT-02]** When a skill is invoked with no argument, the system shall
  resolve the target repo from `git rev-parse --show-toplevel` of the working
  directory.
- **[TGT-03]** The system shall re-resolve the target repo on every invocation
  and shall not assume a previously resolved target carries forward.
- **[TGT-04]** If tack resolves a name to multiple candidates, then the system
  shall present them and prompt the user to choose.
- **[TGT-05]** If tack yields no match or is absent, then the system shall fall
  back to a case-insensitive substring match of the name against the basenames
  of git repos the session has touched.
- **[TGT-06]** If the session touched more than one repo or edits landed outside
  the working directory, then the system shall state the resolved path and ask
  which repo to target.
- **[TGT-07]** While operating on a repo other than the working directory, the
  system shall address it with `git -C` and helper `--repo`/`--worktree` flags
  rather than `cd`.
- **[TGT-08]** Where a write flow targets a non-cwd repo, the system shall
  isolate the work in a dedicated git worktree and tear it down when the flow
  ends.
- **[TGT-09]** If a commit-writing flow resolves a target that has no local
  checkout, then the system shall stop rather than commit to the wrong location.

### CMT — Commit

- **[CMT-01]** When `/anchor:commit` runs, the system shall run the project's
  test suite before staging changes.
- **[CMT-02]** If the test suite fails, then the system shall stop and not stage
  or commit until it passes, including for pre-existing failures.
- **[CMT-03]** Where no test runner is found, the system shall skip the test
  step silently.
- **[CMT-04]** When staging, the system shall stage all changes with
  `git add -A` and read the staged diff before drafting a message.
- **[CMT-05]** If nothing is staged, then the system shall describe the most
  recent unpushed commit, and shall stop if HEAD is already pushed or there are
  no local changes.
- **[CMT-06]** The system shall write the commit message per the commit-message
  template, spending effort on the why rather than the how.
- **[CMT-07]** While HEAD is the default branch, the system shall offer to
  create a feature branch (slugged from the subject) before committing rather
  than commit directly to the default branch.
- **[CMT-08]** When deciding whether to offer a squash, the system shall gate on
  whether HEAD is out for review via `squash-check.sh`.
- **[CMT-09]** If HEAD was authored by another user, is the published
  default-branch tip, or belongs to a ready CR, then the system shall commit as
  a new commit and shall not offer to squash.
- **[CMT-10]** Where squashing is allowed, the system shall recommend squash for
  changes related to the prior commit and a new commit for unrelated changes.
- **[CMT-11]** When a squash amends a pushed draft CR, the system shall follow
  the amend with `git push --force-with-lease`.
- **[CMT-12]** If squashing is not on the table, then the system shall not
  mention it or explain why it is unavailable.
- **[CMT-13]** Where only the message (not the tree) of a ready CR's HEAD is
  wrong, the system shall offer a message-only amend and let the user decide on
  the force-push.
- **[CMT-14]** When changes are staged and a message is drafted, the system shall
  open a visual review of the pending changeset (working tree vs `HEAD`) via the
  review wrapper and shall not commit until the verdict is clean.
- **[CMT-15]** If the pre-commit review returns fix-now comments, then the system
  shall address them in the working tree, re-run tests, and re-review — committing
  only once the verdict is clean, rather than committing and then amending.
- **[CMT-17]** If a `PreToolUse` hook blocks a commit on a substring inside the
  message body, then the system shall surface the conflict rather than use a
  temp-file workaround.
- **[CMT-18]** When the pre-commit review verdict is clean, the system shall
  commit and push in one step.
- **[CMT-19]** If HEAD is the default branch when committing, then the system
  shall create a feature branch first rather than push to the default branch.

### CRR — Create review request

The `create-review-request` skill (formerly `prepare-review`): open a draft CR on
an already-pushed branch and draft its description. Push happens in
`/anchor:commit`, so this flow never pushes and imposes no review gate — its
changeset analysis serves the description and Review guide, not a clean-verdict
check.

- **[CRR-01]** When `/anchor:create-review-request` runs, the system shall require
  an already-pushed branch and gather the changeset via a single recon script,
  acting only on the keys it surfaces.
- **[CRR-02]** If the branch is not yet pushed, then the system shall direct the
  user to `/anchor:commit` (which commits and pushes) rather than pushing itself.
- **[CRR-03]** The system shall open a draft CR against the already-pushed branch
  and shall not push.
- **[CRR-04]** While the branch is behind the default branch, the system shall
  offer to rebase and, since the branch is already pushed, follow the rebase with
  `git push --force-with-lease` per the draft/ready gate.
- **[CRR-05]** While a CR is a draft, the system shall force-push with lease
  freely; while it is marked ready, the system shall ask before force-pushing.
- **[CRR-06]** If local state does not match the CR head, then the system shall
  surface the mismatch and stop rather than draft.
- **[CRR-07]** Before drafting, the system shall resolve open questions (why,
  audience, scope, ordering, verification gaps) with the user rather than park
  them in the description.
- **[CRR-08]** The system shall draft the description leading with why, for a
  reader unfamiliar with the system, using the canonical section headings
  verbatim.
- **[CRR-09]** Before drafting Context, the system shall run an anti-recency
  check dispositioning recent iterations as centerpiece, footnote, or cut.
- **[CRR-10]** The system shall deep-link Review-guide references to the specific
  changed lines rather than to files alone.
- **[CRR-11]** If a claim about prior workflow or current state lacks a citable
  source, then the system shall omit it from the description.
- **[CRR-12]** Where a predecessor CR was captured, the system shall record the
  ordering dependency in the description and, on GitLab, on the forge.
- **[CRR-13]** When presenting the drafted description, the system shall offer
  write / copy-only / edit, defaulting to write.

### FDBK — Resolve feedback

- **[FDBK-01]** When `/anchor:resolve-feedback` runs, the system shall fetch every
  unresolved human-authored review thread on the open CR, including
  non-line-anchored change requests.
- **[FDBK-02]** If there is no open CR or no unresolved feedback, then the system
  shall report that and stop.
- **[FDBK-03]** If local state does not match the CR head, then the system shall
  surface the mismatch and stop.
- **[FDBK-04]** When feedback exists, the system shall present all threads with
  proposed dispositions and confirm with the author before acting.
- **[FDBK-05]** The system shall land review fixes as new commits and shall never
  amend commits the reviewer has seen.
- **[FDBK-06]** When committing fixes, the system shall run the test suite first
  and block the push on failure.
- **[FDBK-07]** When a thread is addressed, the system shall reply into the
  existing thread citing the follow-up commit, and resolve only threads whose
  disposition includes resolve.
- **[FDBK-08]** If a resolve call does not return `resolved`/`isResolved` true,
  then the system shall treat the resolution as not done.

### ISS — Issues

Authoring a single issue (the `issue` skill, ISS-01..06) and surveying the
backlog to pick the next one (the `issues` skill, ISS-07..12).

- **[ISS-01]** When invoked with an issue reference, the system shall update that
  issue against its current body as baseline; otherwise it shall create a new
  issue.
- **[ISS-02]** Before drafting, the system shall gather the why, consumer, and
  acceptance criteria from the author.
- **[ISS-03]** Where creating a new issue and it is unclear whether the need is
  already tracked, the system shall offer to survey issues via the `issues` skill
  rather than searching the forge itself, and shall switch to the update path if
  the need turns out to be already tracked.
- **[ISS-04]** If the author has no approach in mind, then the system shall file
  a problem statement without inventing one.
- **[ISS-05]** When writing a new issue, the system shall assign it to the
  author.
- **[ISS-06]** The system shall lead the issue with why and write for a reader
  unfamiliar with the system.
- **[ISS-07]** The system shall list forge issues for a target repo, defaulting
  to the issues assigned to the invoking user in the open state.
- **[ISS-08]** The system shall interpret the invocation query to refine scope
  (assignee, label, state), keeping the default view when the query does not call
  for something else.
- **[ISS-09]** The system shall rank the listed issues by soonest due date first,
  then by most recently updated, with issues lacking a due date sorted after those
  with one.
- **[ISS-10]** Where the forge has no per-issue due date (GitHub), the system
  shall use the issue's milestone due date as its due date, and treat it as absent
  otherwise.
- **[ISS-11]** The system shall present the ranked issues and recommend the
  top-ranked one as the next to work on, offering to open it for viewing.
- **[ISS-12]** The system shall not write to the forge; its output is limited to
  listing, ranking, and opening an issue for viewing.

### PIPE — Pipeline

- **[PIPE-01]** When `/anchor:pipeline` runs without a watch request, the system
  shall report the commit's current pipeline state once.
- **[PIPE-02]** When the ask is to wait or be notified, the system shall watch the
  pipeline in the background until it settles, then report.
- **[PIPE-03]** If watch is requested while HEAD is unpushed, then the system
  shall tell the user and ask whether to push first or watch the current remote
  tip.
- **[PIPE-04]** When a pipeline has failed, the system shall list each failed job
  linked to its page and offer logs rather than fetch them unprompted.
- **[PIPE-05]** Where a specific job is named, the system shall report or watch
  just that job.
- **[PIPE-06]** If the origin remote is not a recognized forge, then the system
  shall report that there is no pipeline to show.

### RVEW — Visual review integration

- **[RVEW-01]** The system shall launch diff review through the review wrapper,
  never raw `git difftool`, so the sidecar and verdict are populated.
- **[RVEW-02]** While a review runs, the system shall launch the wrapper as a
  background call and read its verdict with the BashOutput tool rather than
  `tail` or command substitution.
- **[RVEW-03]** The system shall interpret the review verdict as `0` clean, `1`
  fix-now, `2` unreviewed, `3` closed-early, and `absent` no-verdict.
- **[RVEW-04]** If the verdict is anything other than `0`, then the system shall
  not treat the review as approval.
- **[RVEW-05]** Where the configured difftool does not speak the sidecar
  contract, the system shall treat the verdict as absent and ask the user
  directly.
- **[RVEW-06]** Where moor is absent, the system shall degrade gracefully to a
  configured difftool or chat rather than fail.

### CONF — Configuration

- **[CONF-01]** When drafting a commit, CR, or issue, the system shall read
  project and global `anchor.*` git config keys, matching names
  case-insensitively.
- **[CONF-02]** If an `anchor.*` key is absent, then the system shall keep its
  default and shall not invent a value.
- **[CONF-03]** Where the user mentions a ticket and `anchor.workTrackerBaseUri`
  is set, the system shall add a Refs trailer/link built from the base URI and
  id; with no mention, it shall add none.
- **[CONF-04]** Where `anchor.reviewBudgetMins` is set, the system shall let it
  steer how aggressively the description is trimmed, without changing the
  register.
- **[CONF-05]** Where `anchor.commitRules`/`crRules`/`mrRules`/`prRules`/
  `issueRules` are set, the system shall layer them onto the relevant defaults,
  preferring forge-specific overrides.

### FORG — Forge integration & output

- **[FORG-01]** Where the project ships a CR or issue template, the system shall
  compose into it — filling its sections, preserving reviewer-facing structure
  verbatim, and stripping author-facing scaffolding.
- **[FORG-02]** If a GitHub issue template is a structured `.yml` form, then the
  system shall surface it for the author to fill in the web UI rather than
  compose prose into it.
- **[FORG-03]** The system shall pass multi-line bodies to the forge by file
  (`--body-file` / `-F description=@`) rather than inline escaped strings.
- **[FORG-04]** The system shall verify markdown rendering against the known forge
  gotchas before presenting a description or issue body.
- **[FORG-05]** If a forge write fails with an auth error, then the system shall
  surface it and ask the user to refresh credentials rather than silently fall
  back to copy-only.

### RULE — Ambient rules

- **[RULE-01]** When a session starts, the system shall inject its ambient rules
  into context via the `SessionStart` hook, expanding `${CLAUDE_PLUGIN_ROOT}`
  placeholders to real paths.
- **[RULE-02]** The system shall omit AI/tooling attribution trailers from
  commits and forge artifacts, adding only a Refs trailer when a ticket is
  mentioned.
- **[RULE-03]** When about to rewrite git history, the system shall route the
  decision through `/anchor:commit` rather than amend, rebase, or force-push ad
  hoc.
- **[RULE-04]** The system shall drive forge operations through `gh`/`glab` and
  route CR creation through `/anchor:create-review-request` rather than a bare
  create.
- **[RULE-05]** While deciding whether a history rewrite is safe, the system shall
  read push state and the CR draft flag fresh at the moment of the rewrite
  rather than from an earlier turn.

### UX — Interaction discipline

- **[UX-01]** The system shall not narrate its plumbing; it shall speak only
  when the user must act or decide.
- **[UX-02]** When a skill starts while a task is already in progress, the
  system shall run silently inside the orchestrator's task list and not create
  its own.
- **[UX-03]** The system shall present multi-way user decisions through
  `AskUserQuestion` with the recommended option first.
