# anchor — Specification

`anchor` is a set of Claude Code skills and ambient rules covering the code-change
lifecycle — filing issues, committing with why-first messages, opening and
describing change requests, resolving review feedback, reporting pipelines,
merging, and releasing — consistently across GitHub and GitLab.

Requirements use [EARS syntax](https://alistairmavin.com/ears) — each is one of:
Ubiquitous (`The <system> shall …`), State-Driven (`While …`), Event-Driven
(`When …`), Optional (`Where …`), or Unwanted Behaviour (`If … then …`).

These requirements were reverse-engineered from the implementation (the skill
prompts under `skills/`, the ambient rules under `rules/`, and the helper
scripts under `scripts/`). They are a derived description of documented
behavior, not an independent authority — review them against the source.

## Concepts

- **Skill** — a user-invocable command the plugin exposes: `/anchor:commit`,
  `/anchor:prepare-review`, `/anchor:review`, `/anchor:resolve-feedback`,
  `/anchor:merge`, `/anchor:release`, `/anchor:issue`, `/anchor:backlog`,
  `/anchor:pipeline`.
- **Forge** — GitHub or GitLab, selected by the `origin` remote; drives the CLI
  choice (`gh` for GitHub, `glab` for GitLab).
- **CR (change request)** — a pull request on GitHub or a merge request on
  GitLab.
- **Qualifier** — the segment of an `anchor.*` key naming what a setting applies
  to: an artifact type (`cr`, `commit`), a forge (`github`, `gitlab`), a skill,
  or a review mode. Distinct from git's own *scope*, the local / global / system
  layer a value was read from. Defined under CONFIG.
- **Destination** — the host an artifact publishes to: `origin`'s host for a
  commit, the target repo's host for everything else. Resolved at run time and
  never typed into a key — the forge qualifies a sanitization rule, where the
  destination is what a finding is measured against: an internal hostname is
  unremarkable in a commit that stays internal. Defined under SANITIZE.
- **Finding** — one span of drafted prose or staged diff that should not reach
  the destination: a denied term, a foreign hostname, a credential shape, a local
  path. Detected by script, resolved by replacement or by an allow term, and
  never published unresolved. Defined under SANITIZE.
- **Default branch** — the repo's integration branch (`main`/`master`),
  resolved from `origin/HEAD`.
- **Ambient rule** — standing guidance a `SessionStart` hook injects into every
  session's context.
- **Review contract** — the tool-agnostic result `review-diff.sh` returns: a
  `verdict` (`approved` · `changes-requested` · `incomplete` · `no-verdict`)
  plus normalized comments and capabilities, produced from the tool's native
  output by an adapter. Defined under DIFF.
- **Review mode** — the shape a review takes: `edit`, where the reviewer is handed
  the drafted artifact and what they save is the artifact, or `diff`, where they
  are shown a changeset and comment on it. Picked by the subject (CONFIG-15).
- **Review tool** — the tool that runs a mode: the user's editor in `edit`, a
  viewer in `diff`. A mode may have several; the two questions are resolved
  apart, so a new viewer is not a new mode.
- **Squash gate** — the deterministic "is HEAD out for review?" decision
  (`squash-check.sh`) that governs squash-vs-new-commit.
- **Deep link** — a line-anchored forge URL in a CR description that lands a
  reviewer directly on the relevant change.
- **Release model** — who owns the version bump for a repo: a CI workflow
  triggered by a published release or a tag push, a bump commit in the repo
  itself, or nobody (no version artifact). Resolved by `release-recon.sh` and
  decisive for the whole release path. Defined under RELEASE.
- **Announcement** — one line the plugin prints when it causes a lifecycle fact
  (`codes.bridgeai.anchor/cr.merged {…}`), for a sibling plugin reading tool
  output to react to. Every key the plugin publishes is declared in `plugin.yml`.
  Defined under EVENTS.
- **revdiff** — a terminal-native visual diff reviewer, and the `diff` mode tool
  `anchor` reaches for when the user has named none. A binary on the machine,
  driven directly and rendered in a terminal `anchor` hosts itself. Optional, and
  the flow that uses it falls back when absent.

## Requirements

### TARGET — Target repo resolution

- **[TARGET-01]** When a skill is invoked with a name argument, the system shall
  resolve that name to a forge host and project path through `gh` and `glab`
  before operating on any repo, over the repos the user can reach on each host
  they are authenticated to.
- **[TARGET-02]** When a skill is invoked with no argument, the system shall
  resolve the target repo from `git rev-parse --show-toplevel` of the working
  directory.
- **[TARGET-03]** The system shall re-resolve the target repo on every invocation
  and shall not assume a previously resolved target carries forward.
- **[TARGET-04]** If a name matches more than one repo, then the system shall
  present the candidates and prompt the user to choose.
- **[TARGET-05]** If no repo matches, then the system shall fall back to a
  case-insensitive substring match of the name against the basenames of git
  repos the session has touched.
- **[TARGET-06]** If the session touched more than one repo or edits landed outside
  the working directory, then the system shall state the resolved path and ask
  which repo to target.
- **[TARGET-07]** While operating on a repo other than the working directory, the
  system shall name that repo in every command it issues (`git -C`, a helper's
  `--repo`), so no command depends on the session's working directory.
- **[TARGET-08]** If a commit-writing flow resolves a target that has no local
  checkout, then the system shall stop rather than commit to the wrong location.
- **[TARGET-09]** The system shall accept `--repo` at any position in
  a helper's arguments, and shall reject an argument it does not recognize rather
  than dropping it. A retargeting flag honored only in a leading position is
  silently ignored anywhere else, so the helper runs against the
  working-directory repo while the rest of the flow uses the target — a
  divergence no later step can detect.
- **[TARGET-10]** The system shall match a bare name against a repo's basename
  exactly, case-insensitively. GitLab's project search answers on substrings, so
  `toolbox` returns `pwsh-toolbox` alongside `cloud-toolbox`, and adopting one
  would act on a repo the user never named.
- **[TARGET-11]** The system shall report a local checkout for a resolved target
  only when the working directory's repo has that target as its `origin`, and
  shall skip a configured forge host it is not authenticated to. Where no host
  could be queried at all, it shall report that rather than that nothing matched.

### COMMIT — Commit

- **[COMMIT-01]** When `/anchor:commit` runs, the system shall run the project's
  test suite after the pre-flight recon and before drafting a commit message,
  discovering the runner itself so it can report progress and act on a failure.
  Where the project or user has a skill named `verify`, the system shall run
  that skill as the test step, once, since Claude Code also asks for it before
  a commit.
- **[COMMIT-02]** If the test suite fails, then the system shall stop and not commit
  until it passes, including for pre-existing failures.
- **[COMMIT-03]** Where no test runner is found, the system shall skip the test
  step silently.
- **[COMMIT-04]** When staging, the system shall stage only the paths the caller
  names, and read the staged diff before drafting a message. A checkout can be
  shared by more than one agent session, so a whole-tree add stages another
  session's in-flight work, which then reaches the review and the commit under a
  message that does not describe it — invisibly, since the diffstat and the diff
  both read as one changeset.
- **[COMMIT-04a]** If a named path has no change at all, then the system shall
  stop rather than stage the rest. The caller named a file it believes it
  changed, so a typo or a path relative to the wrong root would otherwise drop
  that file from the commit with nothing to show it was left behind. A path whose
  change is already staged in full is a separate case, governed by COMMIT-04c.
- **[COMMIT-04b]** The system shall scope the commit to the same paths it staged,
  and shall report staged paths it did not stage rather than committing or
  unstaging them. Scoping only the staging still lets a foreign index entry ride
  into the commit; the entry is another session's to resolve, so it is surfaced,
  left staged, and excluded. Each scoped path is committed as the index holds
  it: a path-limited `git commit` takes the working-tree copy, which carries an
  edit made after the review and any hunk left unstaged. A named path that is
  the new name of a staged rename carries the old name with it, and an amend
  that names no paths changes only the message: a rename committed by its new
  name alone leaves both names in the tree, and an unscoped amend takes whatever
  else is staged.
- **[COMMIT-04c]** Staging a path list shall succeed on every run with the same
  list, for any mix of added, modified, deleted, and renamed paths, and shall
  skip a path whose change is already staged in full. The commit flow stages its
  list twice by design, because a review of newly added files needs them in the
  index before the staged diff will show them. A deletion, and the old half of a
  rename, are absent from both the index and the working tree once staged, and
  naming such a path in a `git add` is fatal to the entire invocation — so a
  staging step that cannot repeat fails the second call and takes every other
  path in the list down with it.
- **[COMMIT-04d]** Where the caller staged only part of a file, the system shall
  commit that file's staged hunks and no others. A path the caller names as
  staged is taken from the index as it stands and never staged; a path named for
  staging that is already partly staged when the flow first stages it is refused
  before anything is staged, so the caller says which it meant. A later restage
  of the same list (the review, after a fix) is the flow's own edits, and
  COMMIT-04e stops anything staged after the review. A `git add` of that path would fold the hunks
  left out into the commit, under a message that does not describe them.
- **[COMMIT-04e]** The system shall commit the scoped paths only while their
  index entries match the ones the COMMIT-14 review showed, and shall otherwise
  stop with nothing committed. The commit reads the index when it runs, so a
  `git add` between the review and the commit (a second `git add -p`, another
  session staging the same file) would land content nobody reviewed. Where a git
  hook changes what the commit carries, the system shall not push it, and shall
  name the paths the hook changed.
- **[COMMIT-05]** If nothing is staged, then the system shall describe the most
  recent unpushed commit, and shall stop if HEAD is already pushed or there are
  no local changes.
- **[COMMIT-06]** The system shall write the commit message per the commit-message
  template, spending effort on the why rather than the how.
- **[COMMIT-07]** While HEAD is the default branch, the system shall offer to
  create a feature branch (slugged from the subject) before committing rather
  than commit directly to the default branch.
- **[COMMIT-08]** When deciding whether to offer a squash, the system shall gate on
  whether HEAD is out for review via `squash-check.sh`.
- **[COMMIT-09]** If HEAD was authored by another user, is the published
  default-branch tip, or belongs to a ready CR, then the system shall commit as
  a new commit and shall not offer to squash.
- **[COMMIT-10]** Where squashing is allowed, the system shall recommend squash for
  changes related to the prior commit and a new commit for unrelated changes.
- **[COMMIT-10a]** When the user chooses a squash, the system shall write the
  combined message before the review, so the text reviewed is the text committed.
- **[COMMIT-11]** When a squash amends a pushed draft CR, the system shall follow
  the amend with `git push --force-with-lease`.
- **[COMMIT-12]** If squashing is not on the table, then the system shall not
  mention it or explain why it is unavailable.
- **[COMMIT-13]** Where only the message (not the tree) of a ready CR's HEAD is
  wrong, the system shall offer a message-only amend, show the corrected message
  verbatim, and ask once for approval of both that text and the force-push.
- **[COMMIT-14]** When changes are staged and a message is drafted, the system shall
  open a visual review of the pending changeset (what the commit will carry, vs
  `HEAD`) with the
  drafted commit message presented alongside the diff (not gated separately in
  chat) via the review wrapper, and shall not commit until the verdict is clean;
  an edited message the review returns (`editedFields`) is used for the commit.
- **[COMMIT-15]** If the pre-commit review returns `changes-requested`, then the
  system shall address its comments in the working tree, re-run tests, and
  re-review — committing only once the verdict is clean, rather than committing
  and then amending.
- **[COMMIT-16]** Where the pre-flight recon reports nothing staged, the system shall
  skip the test suite, since the push-existing and no-local-changes routes make no
  commit and their commits were tested when they were made.
- ~~**[COMMIT-17]** If a `PreToolUse` hook blocks a commit on a substring inside the
  message body, then the system shall surface the conflict rather than use a
  temp-file workaround.~~

  _Retired 2026-10-01: the message is committed from a file (COMMIT-18), so its body
  never reaches a command line for a hook to match. The ID is not reused._
- **[COMMIT-18]** When the pre-commit review verdict is clean, the system shall
  commit and push in one step, performed by a single helper (`commit.sh`) rather
  than as separate agent-run `git commit` / `git push` commands, and shall select
  the push variant (set-upstream / plain / force-with-lease) within that helper.
- **[COMMIT-19]** If HEAD is the default branch when committing, then the system
  shall create a feature branch first rather than push to the default branch, and
  the commit helper shall refuse to commit onto the default branch unless
  explicitly told the direct-to-default case was chosen.
- **[COMMIT-20]** The system shall decide the test gate from the runner's exit
  status, captured on its first invocation, rather than from its output, and shall
  not run the suite a second time to obtain that status.
- **[COMMIT-21]** When the push succeeds, the system shall watch the pipeline it
  triggered and report the outcome, rather than ending at the commit and leaving
  the branch pushed but unverified.
- **[COMMIT-22]** When presenting the direct-to-default-branch choice, the system
  shall describe it as landing the change without a CR, and shall not describe it
  as skipping or bypassing review — the COMMIT-14 review of the diff and message runs
  on both branch choices, so "review" without a qualifier reads to the user as the
  look at the diff they are about to get either way.
- **[COMMIT-23]** When the system opens the review of a pending changeset
  (COMMIT-14), it shall seed a note on each hunk a reader would stop to ask
  about, at most one per hunk and none on a mechanical change, placed per UX-09
  (UX-12). Where the caller hands it notes for the change (REVIEW-30), it shall
  seed those, adding its own only for hunks they leave unexplained. A note the
  reviewer leaves as seeded, or deletes, shall read as read; only an edited or
  a new note is feedback. Where the review tool can't show preloaded notes, the
  system shall open the review without them and list them in the manifest. The
  reasoning a reviewer needs to judge a change otherwise lands in the commit
  message or in comments, where it outlives the review it was written for.
- **[COMMIT-24]** Where the branch has no commit yet, the system shall review
  the pending changeset against the empty tree and shall offer no squash, since
  there is nothing to amend.
- **[COMMIT-25]** When a commit the review covered is pushed to a branch with a
  CR, the system shall give that commit a round in the CR's Review status
  section (REVIEW-31), on someone else's CR under the conditions REVIEW-32 sets.

### PREPARE — Prepare review

The `prepare-review` skill: open (or refresh) a draft CR on an already-pushed
branch and draft its description. Push happens in
`/anchor:commit`, so this flow never pushes and imposes no review gate — its
changeset analysis serves the description and Review guide, not a clean-verdict
check.

- **[PREPARE-01]** When `/anchor:prepare-review` runs, the system shall require
  an already-pushed branch and gather the changeset via a single recon script,
  acting only on the keys it surfaces.
- **[PREPARE-02]** If the branch is not yet pushed, then the system shall direct the
  user to `/anchor:commit` (which commits and pushes) rather than pushing itself.
- **[PREPARE-02a]** If HEAD is the default branch with a clean tree and nothing
  ahead of it, then the recon script shall report `NOTHING_TO_REVIEW=1` and exit
  non-zero, and the system shall report that the flow does not apply and stop.
  There is no branch to open a CR from and nothing to put in one, so the run has
  no route forward. The exit status carries it because a key alone does not: the
  caller is often a chain that named this skill among several, and a state
  reported only in the block can be summarized into "that step was moot" and
  passed over — which drops the CR from the chain silently, with the steps after
  it (a merge, a release) still running.
- **[PREPARE-03]** When the author approves the drafted description, the system shall
  open a draft CR against the already-pushed branch carrying that approved text, and
  shall not push. The description is complete before the CR exists — the Review
  guide's links are placeholders that resolve against the diff (PREPARE-10) rather
  than against a CR URL — so nothing reaches the forge under the author's name before
  they have read it.
- **[PREPARE-03a]** Where the CR is inferred from the branch rather than named
  explicitly, the system shall treat only an open CR as this run's target, and
  shall report a non-open CR it passed over. Neither forge CLI filters its branch
  lookup by state, so a branch name that has been used before resolves to
  whatever CR used it last; a merged or closed CR adopted as the target skips the
  draft-open, and the description then has no open CR to land on. A CR named
  explicitly resolves whatever its state, because the author asked for that one.
- **[PREPARE-04]** While the branch is behind the default branch, the system shall
  offer to rebase and, since the branch is already pushed, follow the rebase with
  `git push --force-with-lease` per the draft/ready gate.
- **[PREPARE-05]** While a CR is a draft, the system shall force-push with lease
  freely; while it is marked ready, the system shall ask before force-pushing.
- **[PREPARE-06]** If local state does not match the CR head, then the system shall
  surface the mismatch and stop rather than draft.
- **[PREPARE-06a]** Where the mismatch is an uncommitted working tree, the system
  shall report that changes are uncommitted and must be committed first, and
  nothing else. The author knows what they changed and why it is not committed
  yet, so a diagnosis of how the tree got dirty, and an argument for why a
  description cannot be drafted against it, is prose to read past to reach the one
  action available.
- **[PREPARE-07]** Before drafting, the system shall resolve open questions (why,
  audience, scope, ordering, verification gaps) with the user rather than park
  them in the description.
- **[PREPARE-08]** The system shall draft the description leading with why, for a
  reader unfamiliar with the system, using the canonical section headings
  verbatim.
- **[PREPARE-09]** Before drafting Context, the system shall run an anti-recency
  check dispositioning recent iterations as centerpiece, footnote, or cut.
- **[PREPARE-10]** The system shall deep-link Review-guide references to the specific
  changed lines rather than to files alone, writing each as an `anchor:<path>#<token>`
  placeholder whose token is a distinctive literal substring of the target line, and
  shall not read a line number off the diff, hash a file path, or assemble an anchor
  itself. A hand-read number still resolves — the forge scrolls to a line the bullet
  is not describing — and nothing about the rendered link reveals it. The token shall
  be matched byte for byte as written, so a token carrying a backslash resolves like
  any other rather than reporting as a line the changeset never touched. The
  description the CR ends up holding shall carry each link as the forge's own line
  anchor.
- **[PREPARE-10a]** If a placeholder's token matches several changed lines, or none,
  then the system shall report the candidate lines with their content and stop, rather
  than take the first match or reduce the link to the file. A token in the file but on
  no changed line, and a token in no line at all, are different authoring mistakes and
  shall be reported as such.
- **[PREPARE-10a1]** The system shall read an `anchor:` written outside a link
  destination as an unresolved placeholder, except where it is a skill invocation
  (`/anchor:<skill>`). A description that names the skill that drafted it is prose the
  author wrote on purpose, and reporting it as broken markup is a fault in the check
  rather than in the draft. It shall likewise read a placeholder in the bare form whose
  token holds a parenthesis as unresolved: the bare form ends at the first `)`, so the
  token is cut there, can still name one line, and its tail would land in the
  description as text.
- ~~**[PREPARE-10b]** Once the CR exists, the system shall expand every placeholder into
  the forge's own line anchor before the description lands, and shall leave the draft
  unmodified where any placeholder is unresolved.~~

  _Retired 2026-10-01: when the expansion runs is a detail of opening the CR; the
  outcome a reader sees is PREPARE-10's last sentence. The ID is not reused._
- **[PREPARE-11]** If a claim about prior workflow or current state lacks a citable
  source, then the system shall omit it from the description.
- **[PREPARE-12]** Where a predecessor CR was captured, the system shall record the
  ordering dependency in the description and, on GitLab, on the forge.
- **[PREPARE-13]** When a drafted description is ready, the system shall present it
  to the user in a visual review (the current description vs. the draft, via the
  review wrapper) before any write prompt, and shall write it to the CR on a clean
  verdict without a further chat confirmation.
- **[PREPARE-13a]** The recon block shall supply the review's baseline as a readable
  path in every case, holding an empty file where no CR holds a description yet. The
  review wrapper takes a pair of paths, so a baseline reported as an empty value is a
  usage error rather than an empty left-hand side, and the review never opens.
- **[PREPARE-14]** If the description review returns no usable verdict, or no
  review tool can open, then the system shall offer the draft outside the tool (its
  path, then an editor where one can open, then the text in its own reply) and offer
  write / copy-only / edit, defaulting to write.
- **[PREPARE-15]** Before opening the description review, the system shall resolve
  every placeholder against the changed hunks of the range (`deep-links.sh --check`)
  and correct each one reported unresolved, so a placeholder cannot survive into the
  expansion that runs against a CR already open.
- **[PREPARE-15a]** Where the description carries a deep link that was not written as
  a placeholder, the system shall check it against the working tree
  (`deep-links.sh --verify`) and re-point every line reported out-of-range, blank,
  outside a changed hunk, or anchored to a file the range doesn't touch. The check
  shall also reject a line part in a shape the forge does not resolve, which the
  line-number checks take as given: a second `#` fragment appended to an anchor drops
  the reader at the top of the diff while reading as a link.
- **[PREPARE-16]** Once the description has landed, the system shall report the
  branch's pipeline, which reports nothing where the CR's commit was already
  reported and reports the new pipeline where a rebase force-push created one.
- **[PREPARE-17]** When the system opens a CR whose source branch will not be deleted
  on merge, the system shall name the condition and offer the forge's remediation,
  applying it only on the user's approval. An unreadable setting shall report as
  unknown rather than as either state.
- **[PREPARE-18]** Once the description has landed, the system shall apply the
  project's own labels and, where exactly one plausibly fits, one of its open
  milestones to the change request, adding to rather than replacing what the CR
  already carries, and asking the author where the choice is not clear.
- **[PREPARE-19]** Where the change request resolves an issue on its own forge, the
  system shall reference that issue in the description with the forge's closing
  keyword, so that merging the change request closes the issue.
- **[PREPARE-20]** When the system redrafts the description of a CR that has a
  Review status section (REVIEW-31), it shall leave the section out of the draft
  and its review, and put it back unchanged when it writes the description.

### REVIEW — Review a change request

The `review` skill: the reviewer's side of the seam `prepare-review` and
`resolve-feedback` sit on either end of. It works in rounds. Each round examines
a CR's diff against the qualities the user has set, groups the findings into
items, makes the fixes the agent would stand behind, and puts the result in front
of the user in revdiff with a note on every item, where the user keeps, changes,
or drops each one in place. Authorship then picks where the kept items go:
suggestions and threads on someone else's CR once the user approves the wording,
or a commit per round on the user's own, ending in the handoff that marks the CR
ready.

- **[REVIEW-01]** When `/anchor:review` runs, the system shall resolve the target
  repo as the other skills do and gather the CR via a single recon script,
  acting only on the keys it surfaces.
- **[REVIEW-02]** The system shall resolve the change request from a number, a
  URL, a source branch, or the current branch, on either forge, and shall take
  the forge from the resolved CR rather than from the working directory's
  `origin`.
- **[REVIEW-03]** Where the resolved CR is not open, the system shall name that
  state and confirm before continuing, rather than spending review attention on a
  change nobody is waiting on.
- **[REVIEW-03a]** Where the resolved CR was written by someone else and is still
  a draft, the system shall name that and confirm before continuing; in
  self-review a draft is the expected state and shall pass without comment.
- **[REVIEW-04]** The system shall read the CR's description before its diff, and
  shall treat what the description does not account for as a finding.
- **[REVIEW-05]** The system shall present the CR's entire diff range in revdiff,
  together with the round's edits and its notes, unfiltered and without a skip
  path, so that what the user decides is decided against changes they have
  seen. Where revdiff cannot open, the system shall say what is missing and stop
  before examining the diff, since the review is carried by notes no other
  viewer takes.
- **[REVIEW-06]** If the tool reports the review as `incomplete`, then the
  system shall name what went unreviewed and re-open the review rather than
  write findings over it. A `reviewCompleteness` of `null` shall be
  read as unmeasured, never as complete.
- **[REVIEW-07]** When the review closes, the system shall treat a note the user
  added as a finding of their own and carry its wording verbatim, rather than as
  feedback blocking the flow.
- **[REVIEW-08]** The system shall place each finding at the narrowest location
  that carries it — the line, else the method or hunk, else the changeset — and
  shall fold a finding it cannot anchor to a line, including a line outside every
  hunk of the diff, into the summary comment rather than dropping it. If the forge
  refuses a write partway, then the system shall report what already posted.
- **[REVIEW-09]** The system shall obtain the user's approval of the exact text
  of every thread and of the summary comment before posting any of them, and
  shall present that text as the rendering the post is built from.
- **[REVIEW-10]** Where the user declines to post, the system shall report the
  review as complete and local, rather than as an abandoned flow.
- **[REVIEW-11]** The system shall pin the CR head SHA when it fetches the diff,
  re-read it before posting, and refuse to post on a mismatch, so that no
  comment anchors to a line the reviewed diff no longer has.
- **[REVIEW-12]** The system shall post either every approved finding at once or
  one named finding at a time, batching the whole-review case into a single
  forge submission where the forge provides one.
- **[REVIEW-13]** The system shall not record a forge review verdict — approving
  or requesting changes as a CR state — and shall report that act as the user's,
  naming the invocation.
- **[REVIEW-14]** The system shall build the previewed text and the posted text
  from one findings document through one code path, so that what the user
  approved is what lands.
- **[REVIEW-15]** The system shall read the review-qualities template before it
  examines the diff and shall weigh the qualities that template lists and no
  others, so that editing the template — adding a quality, dropping one,
  rewriting the output instruction — changes what a review examines with no other
  change.
- **[REVIEW-16]** The system shall examine the diff against each listed quality
  independently, one agent per quality, and shall merge their findings into one
  set, dropping duplicates.
- **[REVIEW-17]** Where the resolved CR was written by the invoking user, the
  system shall run a self-review: the round's edits are made in the user's
  checkout, which shall be on the CR head with nothing uncommitted, the kept items
  land as one commit per round through `/anchor:commit`, and nothing is posted to
  the forge.
- **[REVIEW-18]** When a self-review ends, the system shall offer to mark the CR
  ready and to request reviewers, and shall do neither without the user choosing
  it.
- **[REVIEW-19]** When the findings are merged, the system shall group the
  findings one change resolves into one item, and give each item an id, a slug,
  a severity of critical or suggestion, and a status: applied, proposed, filed as
  an issue, or left as is. The system shall draft the fix of every item that can
  be written as code, critical or suggestion, and shall record each drafted
  item's change on its own, so that one item can be reverted without the others.
  A draft is not kept until the user keeps it (REVIEW-20, REVIEW-21).
- **[REVIEW-20]** Before the review opens, the system shall seed one note for
  every item, on its first site and naming its other sites, headed with the
  item's id, slug, and severity and,
  for an unapplied item, its status, and shall write a table of the items beside
  the diff that is never committed. It shall refuse to open a review over a note
  revdiff would drop, so that a missing note always means the user removed it.
  The round shall be reviewed in two passes: first the items pass, a diff from
  the CR head to the round's tree holding the drafts alone, where the user keeps,
  changes, or drops each item; then, with the dropped drafts reverted and the
  changes made, the whole pass, a diff from the merge base holding the CR with
  the kept fixes in it, seeded with a note per kept item. A draft read inside a
  large CR's diff is hard to tell from the change it comments on, so each item is
  decided before the change is judged as it will land. A note on a line no change
  in its pass is near goes in the table with an excerpt of that line.
- **[REVIEW-21]** When the review closes, the system shall read each item's fate
  from its note: left as seeded or answered with a yes (`ok`, `yes`, `apply`,
  👍) keeps it, deleted or answered with a drop word (`drop`, `ignore`,
  `leave`, `no`) drops and reverts it, and anything else written on it changes
  it. An answer is read where the note sat, whether or not it kept the item's
  header. A deleted row drops the item, and an edited or annotated row changes
  it. A file the user edited from inside the review shall be kept as the user's
  own fix.
- **[REVIEW-22]** Where the CR was written by someone else, the system shall make
  the round's edits in a worktree at the CR head, leaving the user's checkout
  untouched, and shall post a kept applied item whose change is one run of lines
  as a suggestion and any other kept item as a thread, each anchored to the line
  it maps to in the CR head.
- **[REVIEW-23]** When no finding clears the review-qualities template's bar, the
  system shall say so in one line and treat the review as complete: nothing posts
  on someone else's CR, and a self-review goes straight to the handoff.
- **[REVIEW-24]** When a self-review round is committed, the system shall offer
  another round scoped to that round's commit, showing how much each round so far
  changed, and shall end the review when the user declines. The offer shall name
  the repository and the CR in full, say what the round fixed, and say what
  another round would do, so a user answering it after time away can decide
  without scrolling back. It shall recommend another round only when the round
  kept a critical fix, and recommend stopping otherwise.
- **[REVIEW-25]** The system shall remove a round's table, its state, and any
  worktree it made when the round's edits are committed or posted, and when the
  review stops after the round began.
- **[REVIEW-26]** Before examining a CR that already has unresolved review
  threads, the system shall surface them: on the user's own CR it shall offer to
  resolve them through `/anchor:resolve-feedback` first, and on someone else's it
  shall check each against the head and keep the examination from raising an
  open thread again as a finding of its own.
- **[REVIEW-27]** The system shall number a review's rounds within a session and
  record, for each, the items by status, what the user's notes decided and how
  many lines they ran to, and the lines the round changed as a percent of the
  CR's own diff, and shall show that trend with each later round, drawn as one
  bar per round, newest first, above the CR's own on a single scale in the round's table and
  in the offer of another round, the round's table colouring only that round, so
  that a review looping on polish is visible as bars that stop shrinking. The
  system shall name a round by its number from the second round on, and present
  the first as the review itself. The first round's table shall draw the CR's
  own size alone, coloured: its fixes are still proposals the user has not
  answered, so a bar for them would report a round that has not happened.
- **[REVIEW-28]** Before any finding becomes an item, the system shall judge the
  examination's candidates once, as a whole: drop one it can't confirm or that
  the code already prevents, merge ones a single change resolves, classify each
  as critical (merging as written breaks behavior, loses data, exposes
  something, or fails a deploy) or suggestion (it would change what the author
  does), drop a suggestion that wouldn't, fold into each fix what the fix would
  itself draw, and score the change's risk from 1 to 5. It shall aim at no
  number of findings, and shall say how many candidates came back and how many
  survived. Independent lenses each find something; without one judgment over
  their union, every candidate reaches the reader.
- **[REVIEW-29]** When a round finishes, the system shall record each item the
  user dropped as rejected, and a later round's examination and judgment shall
  treat the rejected list as settled, raising an item on it again only where the
  code has since changed in a way that makes it newly valid.
- **[REVIEW-30]** When a round on the user's own CR is committed, the system
  shall hand the commit review each kept item's reason as its note, on the item's
  site in the tree as committed (COMMIT-23), and the round's commit message shall
  name the fixes rather than explain them. The user read each reason on its line
  in the round; the commit review shows it there again, and the message stays a
  record of what changed.
- **[REVIEW-31]** Where the CR is the user's own, the system shall keep a Review
  status section in its description: a table of the CR's commits, how many
  review rounds each has been in, who reviewed it, and the latest round's
  result. It shall name a reviewer by login without an `@`, since a mention in
  a description notifies the person named. It shall key
  each commit by its patch-id, so a rebase that leaves a commit's change as it
  was keeps its rounds and an amend that changes it starts at none. A session's
  round ledger ends with the session; a review of one new commit on top of
  several others leaves no trace there of which ones were never reviewed.
- **[REVIEW-32]** When a review round reaches its verdict, the system shall
  give every commit in the reviewed range another round, by the reviewer, with
  the result `changes-requested` when the round kept an item and `approved` when
  it kept none. A round the user stops records nothing. On someone else's CR it
  shall record only where the description already has the section and the CR is
  out of draft: keeping the section is the author opting in, and a draft is the
  author saying the change isn't ready for review.
- **[REVIEW-33]** When a self-review starts, the system shall read which commits
  the Review status section has no round for. Where some commits have rounds and
  some don't, it shall offer the range from the oldest unreviewed commit to the
  head as the default, with the whole CR as the alternative. Where no commit has
  a round, it shall review the whole CR. Where every commit has one, it shall
  ask, re-reviewing the whole CR by default, with handing the CR off (marking it
  ready, requesting reviewers) as the alternative.

### FEEDBACK — Resolve feedback

- **[FEEDBACK-01]** When `/anchor:resolve-feedback` runs, the system shall fetch every
  unresolved human-authored review thread on the open CR, including
  non-line-anchored change requests.
- **[FEEDBACK-02]** If there is no open CR or no unresolved feedback, then the system
  shall report that and stop.
- **[FEEDBACK-03]** If local state does not match the CR head, then the system shall
  surface the mismatch and stop.
- **[FEEDBACK-04]** When feedback exists, the system shall present all threads with
  proposed dispositions and confirm with the author before acting.
- **[FEEDBACK-05]** The system shall land review fixes as new commits and shall never
  amend commits the reviewer has seen.
- **[FEEDBACK-06]** When committing fixes, the system shall run the test suite first
  and block the push on failure.
- **[FEEDBACK-07]** When a thread is addressed, the system shall reply into the
  existing thread citing the follow-up commit, and resolve only threads whose
  disposition includes resolve.
- **[FEEDBACK-08]** If a resolve call does not return `resolved`/`isResolved` true,
  then the system shall treat the resolution as not done.
- **[FEEDBACK-09]** When fix commits are pushed, the system shall watch the pipeline
  they triggered while it replies and resolves, and shall report that pipeline in
  the summary, so that feedback is not reported as addressed against an unverified
  commit.

### MERGE — Merge

Landing an approved CR into the default branch (the `merge` skill) — the terminal
step after `prepare-review` opens the CR and `resolve-feedback` clears its threads.

- **[MERGE-01]** When `/anchor:merge` runs, the system shall resolve the target repo
  and the open CR for the branch, and shall stop if there is no open CR or it is
  already merged or closed.
- **[MERGE-02]** If local state does not match the CR head, then the system shall
  surface the mismatch and stop rather than merge.
- **[MERGE-03]** Before merging, the system shall check that the CR is marked ready,
  mergeable, pipeline-passing, and approved, plus that review threads are resolved,
  stopping at the first blocking gate.
- **[MERGE-04]** If the CR is a draft, then the system shall not merge it silently and
  shall ask whether to mark it ready and proceed.
- **[MERGE-05]** If the CR conflicts with or is behind its target branch, then the
  system shall stop and route to a rebase via `/anchor:prepare-review` rather than
  attempt the merge.
- **[MERGE-06]** While the pipeline is still running, the system shall watch it to a
  terminal state rather than return control for the user to re-ask.
- **[MERGE-07]** If the pipeline failed, was canceled, or is blocked awaiting a manual
  action, then the system shall stop and report the failed jobs rather than merge.
- **[MERGE-08]** If required approvals are missing, then the system shall stop and
  report what is outstanding, pointing at `/anchor:resolve-feedback` when changes
  were requested.
- **[MERGE-09]** Where a repo has no approval rules and where the commit has no
  pipeline (or every workflow was filtered out), the system shall treat that gate
  as not applicable rather than a failure. A pipeline the system could not read is
  not "no pipeline", and blocks the gate.
- **[MERGE-10]** When unresolved human-authored review threads remain, the system shall
  surface them and confirm before merging, offering to hand off to
  `/anchor:resolve-feedback`.
- **[MERGE-11]** The system shall merge with a commit-preserving merge commit
  (`--no-ff`) by default and shall change the method only where the project or CR is
  configured for a different one, rather than from a judgment about the commit
  history — GitLab's `merge_method` / `squash_option` and the MR's squash flag,
  GitHub's allowed strategies.
- **[MERGE-12]** The system shall preview the resolved merge method and confirm before
  merging through `AskUserQuestion`, without offering a method menu, and shall
  squash only where the forge is configured to.
- **[MERGE-13]** When merging, the system shall use the forge CLI, delete the source
  branch, and guard the merge on the CR head SHA.
- **[MERGE-14]** If a forge write fails with an auth error, then the system shall
  surface it and ask the user to refresh credentials rather than retry or fall back.
- **[MERGE-15]** After a successful merge, the system shall return the local checkout
  to the default branch, pull the merged result, and delete the merged local branch.
- **[MERGE-16]** After a successful merge, the system shall watch the pipeline the
  merge triggered on the target branch and report it without the user asking,
  gated on the same keys as the push-side skills and scoped to the landed SHA the
  forge reported. The branch pipeline the gates read proved the change in
  isolation; the target branch's is the one that deploys, publishes, or releases
  what landed.
- **[MERGE-17]** The system shall report the merge gates as one table — every gate
  once they are green, or the gates checked so far plus the one that blocked — and
  shall surface the resolved merge method through the confirmation prompt alone,
  rather than in prose ahead of it.
- **[MERGE-18]** The system shall read the CR, the checkout, the gates, and the
  merge method through one helper call, and shall land the merge, its read-back
  and announcement, and the local cleanup through another, rather than through
  per-field forge and git commands the skill composes on each run.
- **[MERGE-19]** Where the CR is the user's own and its Review status section
  (REVIEW-31) shows a commit with no review round, the system shall list those
  commits and confirm before merging, offering to hand off to `/anchor:review`.
  Reading the gates shall go on past it, as past open threads (MERGE-10).

### RELEASE — Release

Publishing what has landed (the `release` skill) — the step after `merge`, always
invoked explicitly. The **release model** decides the whole path, so it is
established before anything is proposed or written.

- **[RELEASE-01]** When `/anchor:release` runs, the system shall resolve the target
  repo and gather the release state via a single recon script, acting only on the
  keys it surfaces.
- **[RELEASE-02]** The system shall establish the repo's release model —
  `release-triggered`, `tag-triggered`, `dispatch-triggered`, `bump-commit`, or
  `no-version-artifact` — before recommending a version or editing any file.
- **[RELEASE-03]** The system shall detect a release-triggered model from the CI
  workflow's trigger block rather than from a `release` key appearing anywhere in
  the file, so a job named `release` is not read as a trigger.
- **[RELEASE-03a]** The system shall recognize a release workflow whose only
  trigger is `workflow_dispatch` as CI-owning the bump rather than as
  `bump-commit`, and shall name that workflow. Because a manual-run trigger is
  also the ordinary escape hatch that most workflows carry, the system shall
  require a second signal — the workflow identifying itself as a release, or
  declaring an input that carries a semver level — rather than matching the
  trigger alone. A workflow declaring `release` or a tag trigger alongside
  `workflow_dispatch` shall keep the model that trigger names.
- **[RELEASE-03b]** Where the release model is `dispatch-triggered`, the system
  shall report the inputs that workflow declares and which of them carries the
  semver level, and shall dispatch using that declared name rather than an
  assumed one.
- **[RELEASE-03c]** Where a repo's own documentation states how it publishes, the
  system shall read that statement and follow it over the inferred release model,
  reporting in one line that it did. Where a repo states nothing, the system shall
  behave as though the statement were absent.
- **[RELEASE-04]** While a CI workflow owns the bump — `release-triggered`,
  `tag-triggered`, or `dispatch-triggered` — the system shall not bump or regenerate
  the file that records the version, and shall create only the trigger that model
  names: the forge release, the tag, or the workflow dispatch.
- **[RELEASE-04a]** Where the release model is `dispatch-triggered`, the system
  shall write the notes into the changelog's accruing section without retitling
  it, land them through `/anchor:commit` before dispatching, and confirm the
  dispatch with the author even though no separate notes review ran.
- **[RELEASE-05]** Where the release model is `no-version-artifact`, the system shall
  report what the range contains and stop rather than manufacture a version or a
  publish step.
- **[RELEASE-06]** If no commits have landed since the last release, then the system
  shall report the last release as current and stop.
- **[RELEASE-07]** The system shall anchor the shipping range on the latest version
  tag, falling back to the most recent commit that changed the version, then to
  the root commit.
- **[RELEASE-08]** The system shall classify the range as breaking changes, features,
  fixes, and other, and recommend a semver bump from that classification.
- **[RELEASE-09]** If the version has never been bumped, then the system shall present
  starting versioning as the author's decision rather than default to a bump.
- **[RELEASE-10]** If the current version already has a changelog section, then the
  system shall treat that version as shipped — confirming the next version and
  not rewriting the shipped section's notes.
- **[RELEASE-11]** The system shall write notes describing each change's effect on
  someone using the project, and shall pass them to every consumer by file rather
  than as an inline string.
- **[RELEASE-12]** Where the notes are published as a release body, the system shall
  present them in a visual review before publishing and shall not publish on a
  verdict other than approved.
- **[RELEASE-13]** The system shall confirm the publish with the author even after an
  approved review, because a published release is immediately public and its tag
  may be immutable.
- **[RELEASE-14]** The system shall not publish forge-generated notes in place of the
  categorized notes it drafted.
- **[RELEASE-15]** When a publish fires a release workflow, the system shall watch
  that workflow to a terminal state and then fast-forward the local checkout onto
  the commit it pushed, performing that pull rather than offering it. A dispatch
  returning once the run is queued shall not be reported as a release.
- **[RELEASE-16]** Where the version manifest is generated from a canonical
  descriptor, the system shall bump the descriptor and regenerate rather than edit
  the manifest.
- **[RELEASE-17]** Where the release model is `bump-commit`, the system shall shape
  the bump commit to the repo's prior convention and land it through
  `/anchor:commit` rather than running git commit and push itself.
- **[RELEASE-18]** Where a changelog holds an accruing Unreleased section, the system
  shall retitle it to the new version rather than insert a new section above it.
- **[RELEASE-19]** The system shall not cascade from a merge into a release;
  `/anchor:merge` shall name `release` as the next step without invoking it.

### ISSUES — Issues

Authoring a single issue: gathering the intent, drafting it, filing it, and
triaging it with the project's own labels and milestones (the `issue` skill).
Working the backlog it lands in is the `backlog` skill's half, in BACKLOG below.

- **[ISSUES-01]** When invoked with an issue reference, the system shall update that
  issue against its current body as baseline; otherwise it shall create a new
  issue.
- **[ISSUES-02]** Before drafting, the system shall gather the why, consumer, and
  acceptance criteria from the author.
- **[ISSUES-03]** Where creating a new issue and it is unclear whether the need is
  already tracked, the system shall offer to survey issues via the `backlog` skill
  rather than searching the forge itself, and shall switch to the update path if
  the need turns out to be already tracked.
- **[ISSUES-04]** If the author has no approach in mind, then the system shall file
  a problem statement without inventing one.
- **[ISSUES-05]** When writing a new issue, the system shall assign it to the
  author.
- **[ISSUES-06]** The system shall lead the issue with why and write for a reader
  unfamiliar with the system.
- **[ISSUES-07]** When writing an issue, the system shall apply the labels that fit
  it from the target project's existing label set, and shall not create a label the
  project does not define.
- **[ISSUES-08]** Where more than one of those labels plausibly fits, or where none
  fits an issue a reader would expect to be labelled, the system shall ask the
  author rather than choosing, and shall accept no label as the answer.
- **[ISSUES-09]** When writing an issue, the system shall consider only the
  project's open milestones, attaching one where exactly one plausibly fits, asking
  the author where several do, and attaching none where none does.
- **[ISSUES-10]** Where the issue already exists, the system shall only add the
  labels and milestone it lacks, and shall not remove or replace the ones already on
  it.
- **[ISSUES-11]** The system shall present the labels and milestone with the drafted
  body for one approval rather than gating them separately.
- **[ISSUES-12]** The system shall head that presentation with a link to where the
  write lands — the target project's issue list on a create, the issue itself on an
  update — above the title and the labels and milestone.
- **[ISSUES-13]** Where a batch of issue edits plans a release, the system shall
  carry the milestones it creates, edits, or closes (title, due date, state,
  description) as items of the same batch review, named by title, and shall
  publish them before the issues, so an issue can name a milestone the batch
  creates.
- **[ISSUES-14]** When the system sets a milestone's due date, it shall store the
  calendar date the reviewer approved, and shall report a stored date that
  differs from it.

### BACKLOG — Backlog

The backlog as a body of work — grooming it, planning against it, sequencing it,
and picking what to work on next (the `backlog` skill). The requirements below
cover the survey: listing and ranking what is filed, recommending a next pick,
and writing nothing.

- **[BACKLOG-01]** The system shall list forge issues for a target repo, defaulting
  to the issues assigned to the invoking user in the open state.
- **[BACKLOG-02]** The system shall interpret the invocation query to refine scope
  (assignee, label, state), keeping the default view when the query does not call
  for something else.
- **[BACKLOG-03]** The system shall rank the listed issues by soonest due date first,
  then by most recently updated, with issues lacking a due date sorted after those
  with one.
- **[BACKLOG-04]** Where the forge has no per-issue due date (GitHub), the system
  shall use the issue's milestone due date as its due date, and treat it as absent
  otherwise.
- **[BACKLOG-05]** The system shall present the ranked issues and recommend the
  top-ranked one as the next to work on, offering to open it for viewing.
- **[BACKLOG-06]** The system shall not write to the forge; its output is limited to
  listing, ranking, and opening an issue for viewing.

### CI — Pipeline

- **[CI-01]** When `/anchor:pipeline` runs without a watch request, the system
  shall report the commit's current pipeline state once. If the forge could not
  be read, then the system shall report that, with the forge's error, rather than
  "no pipeline", and shall not poll a read that failed.
- **[CI-02]** When the ask is to wait or be notified, the system shall watch the
  pipeline in the background until it settles, then report.
- **[CI-03]** If watch is requested while HEAD is unpushed, then the system
  shall tell the user and ask whether to push first or watch the current remote
  tip.
- **[CI-04]** When a pipeline has failed, the system shall list each failed job
  linked to its page and offer logs rather than fetch them unprompted.
- **[CI-05]** Where a specific job is named, the system shall report or watch
  just that job.
- **[CI-06]** If the origin remote is not a recognized forge, then the system
  shall report that there is no pipeline to show.
- **[CI-07]** The system shall resolve a pipeline by the commit it ran on,
  independent of the ref that triggered it, so that a run fired by a published
  release or a pushed tag — which carries the tag as its branch — resolves for
  that commit.
- **[CI-08]** Where a forge reports several runs for one commit (GitHub's one
  run per workflow), the system shall report a single verdict over them — each
  workflow's latest attempt, then the least-settled and worst-off run — and shall
  accept a named workflow to scope the verdict to one run.
- **[CI-09]** Where a caller gates on the forge's own merge checks rather than
  on the commit's overall CI state, the system shall report the commit's most
  recent run alone, without folding the commit's other runs into the verdict.
- **[CI-10]** The system shall report every run for the commit together with
  each run's jobs, whatever state the commit is in, so that the report says what
  ran and not only whether it passed.
- **[CI-11]** The system shall present that breakdown as a table, one row per
  job, marking each row with an emoji for its normalized state that separates the
  states wanting attention (failed, canceled) from the expected ones (success,
  skipped, manual) and from the in-flight ones.
- **[CI-12]** Where there is no pipeline to tabulate — no pipeline for the
  commit, an unrecognized forge, or a single tracked job — the system shall
  report in one line and draw no table.
- **[CI-13]** When a skill has pushed a commit, or landed one through a merge,
  the system shall watch the pipeline that commit triggered until it settles and
  report it, without the user asking.
- **[CI-14]** Where every run for a commit has already been reported, the
  system shall not report them again, so that successive skills acting on one
  commit produce one report; a run no report has covered — including one that
  only opening the change request started — shall still be reported.
- **[CI-15]** When the system starts watching a pipeline that supersedes one an
  earlier watch is still polling for the same work — a later commit on the same
  branch, the commit a merge landed from it, or a run a release dispatched on it
  — the system shall stop the earlier watch, report only the newer pipeline, and
  say which watch it stopped. Two reports on one line of work leave the user to
  work out which one counts, and the older one no longer says where it stands.
- **[CI-16]** Where a commit is named by an abbreviated sha, the system shall
  resolve it to the full commit before looking up its pipeline, and shall fail
  naming the value where it names no commit. The forges match a run's commit on
  the full sha only, so an abbreviated one finds no runs and reads as a commit
  CI never touched.

### DIFF — Review integration

Diff review is tool-agnostic. Each review skill launches review through one
dispatcher (`review-diff.sh`), which resolves the diff range, drives the
configured mode in the configured tool, and normalizes that tool's native output
to the contract below via an adapter. Which mode, and its default, is CONFIG-15's
to say — stated once there rather than restated per consumer. The shape borrows
its two axes — an outcome `verdict` kept separate from a per-comment `action` —
from SARIF (`result.kind` vs `result.level`) and reviewdog; its verdict names
from GitHub's pull-request review states; and its "the tool cannot express
this" nullability from SARIF's `notApplicable`.

**Normalized result** — emitted on stdout as `REVIEW_VERDICT=<verdict>` and
`REVIEW_OUTPUT=<json>`, where the JSON is:

```
{
  mode:               "edit" | "diff",
  tool:               string,       // the tool that ran it — an editor, or a diff tool
  verdict:            "approved" | "changes-requested" | "incomplete" | "no-verdict",
  reviewCompleteness: "complete" | "partial" | null,   // null = tool cannot say
  reviewer:           string | null,
  comments: [{
    body:        string,
    target:      "line" | "file" | "changeset",
    file?:       string,        // present when target != changeset
    startLine?:  number,        // 1-based, inclusive; present when target == line
    endLine?:    number,        // 1-based, inclusive; == startLine for a single line
    side?:       "old" | "new", // defaults to new
    suggestion?: string,        // proposed replacement for the anchored range
    quote?:      string,        // the context-file lines a note there sat on
    raw?:        string         // the tool's verbatim comment text
  }],
  editedFields: [{ target: "commit-message" | "description" | "issue-body" | "release-notes",
                   original?: string, edited: string }],
  capabilities: {
    producesVerdict: bool, perHunkReview: bool,
    editableCommitMessage: bool, editableDescription: bool, sideMarkers: bool
  },
  raw: { exitCode: number | "absent", output?: string }
}
```

**Verdict mapping:**

| `verdict` | `diff` (revdiff) | `edit` | meaning |
|---|---|---|---|
| `approved` | a note on the Verdict section's Accept line (DIFF-42) | saved, changed or not | clean — proceed |
| `changes-requested` | a note of the reviewer's, and none on the Verdict section (exit 10) | — | blocking feedback to address |
| `rejected` | a note on the Verdict section's Reject line | exited 2 (`ZX`), or saved empty | the reviewer declined — nothing the review gates happens, and nothing falls back |
| `incomplete` | — | — | not every hunk was reviewed; for a tool that tracks per-hunk review (`capabilities.perHunkReview`) |
| `no-verdict` | exit 1, or `q` with no note of the reviewer's, or notes on both Verdict lines (`raw.exitCode` `undecided`) | closed without saving (`undecided`), or any other non-zero exit | no usable verdict — the cause (closed early, tool error, an aborted edit, or no verdict chosen) is read from `raw.exitCode` and `capabilities.producesVerdict` |

`edit` has no `changes-requested` row because it returns text, not comments: an
editor's whole answer is the revised artifact, which is why the column below
`changes-requested` is empty rather than mapped to some exit code: asking for
changes there is exit 3, which reopens the review in `diff` (DIFF-39).

- **[DIFF-01]** The system shall launch diff review through the dispatcher, never
  raw `git difftool`, so the result is normalized and the verdict is populated.
- **[DIFF-02]** While a review runs, the system shall launch the dispatcher as a
  background call and read its result with the BashOutput tool rather than `tail`
  or command substitution. The launch shall end the turn: every question the flow
  needs answered before the review is settled before the launch, and no blocking
  question is asked while the review is open, since the background call's
  completion cannot reach the session until that question is answered.
- **[DIFF-03]** The system shall drive the mode CONFIG-15 selects through one
  adapter per mode, and shall report the mode and the tool that ran it as separate
  fields, so a consumer reads the shape of the review apart from what happened to
  run it. A mode adapter shall own what every tool running that mode needs alike —
  locating the tool, hosting it, seeding the header, and shaping the normalized
  result — and shall delegate to a per-tool adapter only what is that tool's own:
  its invocation, its output parsing, and the mapping from its exit status onto a
  verdict. A second tool for a mode is then an adapter file beside the first rather
  than a second copy of the mode.
- **[DIFF-04]** The system shall report the verdict as one of `approved`,
  `changes-requested`, `incomplete`, or `no-verdict`, mapped from the tool's
  native signal per the verdict table.
- **[DIFF-05]** If the verdict is anything other than `approved`, then the system
  shall not treat the review as approval.
- **[DIFF-06]** Where the verdict is `no-verdict`, the system shall read its cause
  from `raw.exitCode` and `capabilities.producesVerdict` and ask the user rather
  than proceeding.
- **[DIFF-07]** The system shall represent a dimension a tool cannot express as
  `null` (e.g. `reviewCompleteness`) rather than a fabricated value, so a
  consumer distinguishes "unsupported" from "checked and found none".
- **[DIFF-08]** The system shall carry comments ungraded — no per-comment
  severity, action, or priority field — and shall treat every comment a
  `changes-requested` verdict accompanies as feedback to address. Whether
  feedback blocks is the verdict's to say, so a per-comment tier would give a
  consumer a second, disagreeing answer.
- **[DIFF-09]** The system shall carry each comment's tool-verbatim text in
  `raw` so feedback the normalization cannot represent is not lost.
- **[DIFF-11]** The system shall resolve both axes against what can actually
  open. On the **mode** axis: a mode the subject picked (CONFIG-15) that cannot
  open — `edit` with no editor to reach (DIFF-16, DIFF-17) — shall give way to
  one that *can*, since it is a choice nobody made; a mode the caller
  asked for explicitly shall be kept whether or not it can open, so its own report
  names the missing piece, substituting a viewer for a requested `edit` answering a
  different question than the caller asked. Giving way requires the other mode to
  be openable in full, program and host together (DIFF-25a): where neither can
  open, the subject's mode is kept, because a report naming the editor that is
  missing serves the user better than one naming a viewer they are no closer to
  reaching. On the **tool** axis there is no substitution: a viewer the user named
  is the viewer reported, installed or not, and the flow hands off to the fallback
  ladder (DIFF-20) rather than opening a tool nobody chose and returning its
  verdict as theirs.
- **[DIFF-12]** If the dispatcher reports no parseable verdict — no
  `REVIEW_VERDICT` line, empty output, or output the consumer cannot read — then
  the system shall treat the review as `no-verdict`, halt the action the review
  gates, and verify with the user in chat. Absent output is never approval; a
  dispatcher that fails before reporting produces silence, which is
  indistinguishable from success unless the consumer treats it as failure.
- **[DIFF-13]** Where the selected mode is `edit`, the system shall open the
  drafted artifact in the user's editor with the change under review below a
  scissors line, adopt the saved text verbatim as the artifact, and return it in
  `editedFields` rather than re-drafting from it. It shall not strip lines
  beginning with `#`, which are headings in the markdown artifacts it carries.
  The buffer shall be named for the artifact's own format — `.md` for the three
  markdown artifacts, git's `COMMIT_EDITMSG` for a commit message — since an
  editor picks its syntax mode and its markdown preview from the name rather
  than the content, and a reviewer reading a description wants the rendered
  shape. The context below the scissors line shall be marked as a comment in that
  format: `#` lines under git's own `# ---- >8 ----` line for a commit message,
  an HTML comment for markdown.
- **[DIFF-13a]** The system shall name the `edit` buffer for the object under
  review, by the reference its caller passes (`--name`: `<repo>#<number>`,
  `<repo>!<iid>`, `<repo>@<version>`) and otherwise by the repo, the branch, and
  the artifact, in a directory of its own, and shall
  start an editor that shows paths relative to its working directory in that
  directory. The buffer's name is what an editor's title or status line shows,
  and a random temp path there says nothing about which review is open; a
  directory per buffer keeps two reviews of the same artifact apart on disk.
- **[DIFF-14]** The system shall take the editor's save as the reviewer's
  answer: a saved buffer is `approved` and its text is the artifact, a buffer
  saved empty is `rejected`, and a buffer left unsaved is `no-verdict` with
  `raw.exitCode` `undecided`, asked about as DIFF-42 asks, with nothing the
  review gated published. Saving costs the same keystroke as quitting and is an act
  rather than the absence of one, where a quit is also what an editor does when
  the reviewer walked away from it. The save shall be read from the buffer
  rather than from how the editor left, so a draft saved into a terminal that
  went away afterwards is still the answer. An editor that exits 2 shall reject
  whatever was saved (DIFF-44); one that exits non-zero otherwise (vim's `:cq`)
  shall halt with `no-verdict`, since a failing editor exits the same way. Where
  nothing was saved, the result shall name the cause rather
  than carry a numeric status — the reviewer left without saving, or the
  terminal it was drawing in went away, could not be opened, or there was none
  to open — since a number would attribute to the editor an exit it never made
  and leaves the user a status to interpret in place of the thing to do. A cause
  the reviewer can act on shall be reported with its remedy, and a terminal
  taken down mid-edit shall be reported as re-openable rather than as a tool
  that cannot grade the change. Where an editor the system knows returned
  without waiting — a GUI editor invoked without the flag that makes it block
  (DIFF-16) — the report shall name that editor and that flag, since nothing was
  written in that case either and reporting it as the reviewer declining to save
  attributes to them a decision they were never offered.
- **[DIFF-15]** Where `edit` is selected for a review that has no drafted
  artifact, the system shall report `no-verdict` naming the configuration that
  resolves it, rather than reporting a diff it cannot show as reviewed.
- **[DIFF-16]** The system shall resolve the editor as git resolves it
  (`core.editor`, then `VISUAL`, then `EDITOR`), and shall treat a no-op editor
  supplied by the environment as unset, so a review that opened nothing is never
  read as approval. Where none of those name one, it shall continue past git's
  chain — since an editor the user never configured is still an editor they
  have, and the alternative is refusing a review on a machine where `git commit`
  would have opened one. Which rung it continues to shall turn on whether a
  terminal can be hosted: with one, git's own compiled default, which is both
  the editor a plain `git commit` opens there and the one that renders in the
  pane the system labels and focuses (DIFF-25, DIFF-29, DIFF-30); with nowhere
  to put a terminal, a blocking editor found on `PATH`, which is then the only
  rung that reaches anything. Where neither answers, the compiled default shall
  still name the editor, so the launch reports the host it cannot find rather
  than an absent editor the user does have. The compiled default shall be read independent of the
  ambient terminal and of the no-op values already discounted above: git names no
  editor at all when the terminal it was handed is dumb, which answers for git's
  own stdio rather than for a tool that renders in a terminal the host opens
  (DIFF-17), and an agent harness that leaves no terminal behind is the common
  case here rather than the exception. A found editor shall be invoked with the flag that makes
  it block, and the search shall be limited to editors whose blocking flag is
  known, since a non-blocking editor returns before the user has typed and reads
  as an artifact they approved.
- **[DIFF-17]** When asked to report how a review resolves rather than run one, the
  system shall emit the mode a review would run
  in and the tool that would run it, report where each of those two came from,
  name the preferred mode whenever it substituted another, report
  whether anything usable is available, and shall launch nothing. Availability
  shall take both halves of what a mode needs — the program *and* somewhere to
  draw it (DIFF-25a) — in `diff` as in `edit`: a viewer that is plainly installed
  with no terminal to render it in opens no more than an editor with nowhere to
  go, and reporting it available sends the caller to launch a review the host
  answers with `no-host`. It shall not
  substitute `edit` for an absent viewer, which would answer a different question
  than the caller asked. It shall additionally report, on its own axis, whether an
  `edit` review would reach an editor — resolvable per DIFF-16 *and* with
  somewhere to open it — since the editor is a rung the
  fallback ladder offers rather than a viewer the probe selects, and offering it
  where a launch would reach nothing dead-ends the user in a host error.
- **[DIFF-18]** The system shall drive git's difftool as a `diff` tool, and
  shall read its verdict from the working tree rather than from the tool. A
  difftool speaks no contract of its own, so a review that only put the changeset
  on screen would end where an absent viewer's does — the user has read
  something, which makes "you saw it, approve?" the natural next question and a
  rubber stamp the likely answer. What it does have is a way for the reviewer to
  *write*: the system shall snapshot every reviewed file before the tool opens,
  and shall report each file the reviewer changed, carrying the diff of what they
  wrote as the comment. Edits are therefore `changes-requested` and an untouched
  tree is `approved`, since the write is an act where reading is not. The
  reviewer shall need no marker convention — a fix typed into the code, a
  question in the file's own comment syntax, and a `TODO:` are all the same
  signal, and the reading of them is the model's (UX-08). The system shall not
  read the tool's own exit status as a verdict, since `git difftool` drops it and
  tools disagree about what non-zero means; a failure to launch is a review that
  never happened. Where a side of the review is not the working tree (the index,
  or a commit range such as a CR, the previous commit, or the full branch), git
  hands the tool temp copies, so the system shall return `no-verdict` rather than
  read an untouched tree as approval.
- **[DIFF-19]** Where a git-range review's subject is not the local `HEAD`, the
  system shall accept a caller-supplied title and detail rows and use them in
  place of the computed header, so a range fetched from another author's change
  request is not labelled with the reviewer's own last commit.
- **[DIFF-20]** Where a review is ungraded — nothing usable installed, or a
  result that is `no-verdict`, `incomplete`, or carries no parseable verdict —
  the system shall offer a rung that produces a real answer rather than a
  question that treats the launch as one. It shall not ask whether a shown diff
  is approved: a window that opened is not evidence it was read, and the two
  cases are indistinguishable. For a drafted artifact it shall surface the
  draft's own file path and, where DIFF-17 reports an editor is reachable, offer
  `edit` mode, whose saved buffer returns a graded result through DIFF-13. Its floor shall be reading the change in the conversation — the
  artifact in full, or a changeset walked file by file — never a summary
  standing in for the change, since approval of a summary grades the summary.
- **[DIFF-20a]** Where a review is ungraded, the system shall open and close its
  reply with an error banner naming what the tool did and that nothing was
  published, and shall take approval to publish only through a choice that names
  the remote action and that no tool graded it. A bare acknowledgement in free
  text shall not publish, since a walk-through ending in a question reads like
  the ask before a review.
- **[DIFF-21]** If the resolved range holds no changes, then the system shall
  report `no-verdict` with `raw.exitCode` `empty-range`, name the repo the range
  resolved against and how that target was resolved, and launch no viewer. A
  viewer opened on an empty diff is closed exactly as an approved review is, so
  launching one manufactures approval for a changeset nobody saw; an empty range
  is also how a review aimed at the wrong checkout presents. Under `--untracked`
  a new file other than the review's context file is a change, so a batch whose
  items are all new opens.
- **[DIFF-22]** Where a local-changes review stages so that new files appear in
  the range, the system shall stage only the paths the caller names, and shall
  stop when a named path has nothing to stage. The review has to cover the same
  files the commit will, so its staging follows COMMIT-04 rather than sweeping the
  tree — a reviewer handed another session's file grades a changeset that is not
  the one under review.
- **[DIFF-23]** Where a `changes-requested` review is re-opened on a revised
  draft, the system shall compare it against the draft the reviewer graded rather
  than the artifact the forge holds. The second pass is asked to grade what the
  feedback changed, and re-showing the original comparison answers the question
  the first pass already answered.
- **[DIFF-24]** Where a consumer probes for the mode (DIFF-17), it shall probe
  under the same skill the launch will use, and shall name the tool it opens
  whenever that tool renders outside the terminal the user is watching. The probe
  resolves per skill (CONFIG-15), so one run without the skill answers for another
  skill's default and reports a tool the review will never open; and a review
  waiting in a window behind the terminal is indistinguishable from nothing having
  opened, which reads as a step that was skipped rather than one blocking on the
  user.
- **[DIFF-25]** The system shall open a review that needs a terminal where the
  session it was called from can put one — a popup or a split of that session —
  and shall return the borrowed screen when the review closes. The review and the
  terminal that asked for it stay in one place, where a separate window can rest
  behind the one the user is watching, and a review silently waiting on them is
  indistinguishable from one that never opened. Where the host addresses a
  session rather than a terminal application, it shall be selected on whether the
  calling session can be named. The same answer shall serve the probe (DIFF-17)
  and the launch so the two cannot disagree.
- **[DIFF-25a]** The system shall resolve that host independently of the review's
  mode, from one ranked set, so `edit` and `diff` reach equally far. A host is a
  place to draw a program the reviewer reads and types into, and which program it
  is does not change where it can be drawn; resolving them apart is what leaves
  one mode reaching a host the other cannot, so a machine that can open a drafted
  document cannot be shown its own changeset. A host that serves one mode and not
  the other shall say so rather than be reached by a second selector — a blocking
  GUI editor's own window serves `edit` alone, since no such window renders a
  changeset. The set shall hold no host that cannot be selected: the system runs
  as a plugin, whose scripts the harness invokes with no controlling terminal, so
  a host addressing the caller's own terminal is a rung the fallback ladder
  reasons about for nothing.
- **[DIFF-25b]** The system shall take a host the user names, a program that
  runs a command string in a terminal of the user's choosing and returns its
  status, in place of the shipped set, and shall link to where the hosts and
  that option are documented wherever it reports that no host can open. The shipped set covers the terminals the
  system can script, and a terminal outside it otherwise leaves a review that
  needs one with no way to open at all.
- **[DIFF-25c]** Where the host addresses a session the user can move off, the
  system shall open the review on that session without selecting it, and shall
  mark the session as waiting on the reviewer where the terminal shows the user
  every session, clearing the mark it set when the review closes. A review
  arrives partway through a flow, often after the user has moved to other work,
  so selecting its session switches the screen under them and hands keys typed
  for the other session to the review. The mark says a review is waiting without
  taking the screen; it is attempted rather than required, so a mark the
  terminal refuses leaves the review to run, and the system clears it itself
  rather than relying on hooks the user may not have installed.
- **[DIFF-26]** The system shall run the command it opens in a split in the
  directory and the environment it resolved that command against — at least the
  working directory, the executable search path, the locale, and the editor a
  review tool spawns for itself. A split's command is not run through a login
  shell, so it starts in the terminal application's own environment and whatever
  directory that inherits: a tool resolved against the caller's environment is
  looked up again in one that lacks it and the pane dies before rendering
  anything, and a range of refs resolved against the repo under review is
  re-resolved wherever the pane happens to stand, which draws a different repo's
  diff — or an empty one, where that repo is clean.
- **[DIFF-27]** The system shall drive the diff viewer itself rather than
  through another plugin's launcher, and shall report `no-verdict` naming the
  missing piece where the viewer is absent or the session cannot be split.
  Reaching into a sibling plugin's file layout couples the review to a path that
  plugin is free to change.
- **[DIFF-28]** The system shall wait on an open review for as long as the
  reviewer takes, and shall end the wait early only on evidence that no result is
  coming — the pane closing without reporting one. A review is read and typed
  into at human pace, so an elapsed-time cap generous enough not to interrupt is
  too long to be a useful guard, and what it reliably does instead is discard a
  draft mid-edit. Where the evidence is unavailable rather than negative, the
  system shall keep waiting. A closed pane counts as that evidence only once the
  result is confirmed still absent: quitting the tool is what closes the pane, so
  the ordinary end of a review is a status written and a pane gone in the same
  breath, and a liveness check landing in that moment answers for a moment
  already past.
- **[DIFF-29]** The system shall carry the calling session's tab label onto the
  split it opens, marked to say a review is waiting there, and shall open the
  review anyway where the label cannot be set. The terminal draws the tab from
  the session holding the focus (DIFF-30), so a pane carrying no label of its own
  empties the tab the user navigates their windows by, for as long as the review
  is open. The mark belongs in that label rather than in the pane's own
  appearance, which no escape sequence reaches and which would cost the split a
  profile of its own.
- **[DIFF-30]** The system shall move the input focus to the split it opens. A
  split opened through the terminal's scripting interface is created without
  being selected, so the review draws in a pane the keyboard does not reach and
  the reviewer types into the session that is waiting on them instead.
- **[DIFF-31]** Where the verdict is `approved`, the system shall report the
  comments it carries without gating the operation on them, and shall carry out
  a comment that asks for follow-up work to be filed rather than fixed now. A
  reviewer who approves and still comments has chosen not to block; leaving the
  request unactioned makes blocking the only way to be heard.
- **[DIFF-32]** When the user gives feedback in chat while a review is open, the
  system shall acknowledge the feedback, state that the review is still open, and
  halt the flow, leaving the open review in place. When that review closes, the
  system shall apply the chat feedback together with the review's result and open
  a new review of the revised artifact, and shall proceed only on the new
  review's verdict, whatever the first one returned. Closing the open review from
  the chat side could discard what the reviewer has written in it, and a verdict
  given before the chat feedback grades a version that will not land.
- **[DIFF-33]** Where a local-changes review names a partly staged path, the
  system shall show the index against `HEAD` rather than the working tree, and
  shall return `no-verdict` with `raw.exitCode` `staged-unsupported` when the
  tool's verdict is read from edits to the working tree. The tree holds the hunks
  the commit leaves out, so a working-tree review grades a changeset that is not
  the one that lands; and git opens a staged diff's index side as temp copies,
  so a reviewer's edits there never reach a file and read as an untouched tree,
  which is approval.
- **[DIFF-34]** Where the caller names the skill that opened a review, the
  system shall lead the review's header with that skill and with what approving
  the review hands it, ahead of the rows the caller supplied. A review opens
  partway through a flow and can wait while the user works elsewhere, so the
  reviewer often returns to it without remembering which flow is waiting on
  them or what their answer sets off.
- **[DIFF-35]** Where the caller passes notes to preload, or asks for untracked
  files to be shown, the system shall hand them to a tool that can carry them and
  return the set of notes the reviewer left, and shall report `no-verdict` with a
  named cause for a tool that cannot, rather than opening a review that silently
  drops them. A note on an unchanged line shall come back anchored to its file and
  line.
- **[DIFF-36]** Where the review tool lists files beside the diff, the system
  shall show the review's header as a file at the root of that list, read back a
  note on it as feedback on the drafted artifact the header carries, and shall
  keep the file out of what git stages or reports, during the review and after it.
  A review that brings its own table to that place (a batch, a review round)
  shall show that table there in place of the header, kept out of git the same
  way, and shall read a note on it back as a note on the table. Where that file
  is the only one under review, the system shall open it without the list, since
  a tool that fills a one-file list with that file's headings shows what reads as
  a list of files the review does not hold.
- **[DIFF-37]** Where a local-changes review returns `changes-requested` in a
  tool that can preload notes, the system shall keep the changeset as the review
  closed, and shall re-open the review on what changed after that point, with a
  reply to every comment the reviewer left: on the line it concerns, opening with
  what the reviewer asked and saying whether it was answered, done as asked, or
  done differently, and listed together at the head of the review's context file.
  The system shall refuse to seed a reply round that leaves a comment unanswered,
  and shall read a reply returned as seeded, or deleted, as read rather than as
  feedback. A reviewer whose notes are questions otherwise has to find the
  answers in the conversation, and re-showing the whole changeset leaves them to
  work out which lines answered them and whether each request was carried out or
  reasoned away.
- **[DIFF-38]** Where a review's context file gives the size of the change, the
  system shall draw it as bars, and where the review re-opens as a reply
  (DIFF-37), shall stack the size of each pass on that one scale, newest first:
  what changed since the last review closed, what changed after each review
  before it, and the change as the first review saw it, colouring only the pass
  under review and setting each earlier one apart below it. A size given for the
  whole change alone hides how much each answer moved it, a percent per pass has
  to be read and compared in the head, a first review drawn differently from
  the ones after it leaves nothing to compare against, and a stack coloured
  throughout gives the pass under review no more weight than the history under
  it. The longest bar shall span a third of the full width where the largest
  pass in the stack is up to 100 lines, two thirds under 1000, and the full
  width beyond, read from the stack each time it is drawn, since a full-width
  bar for a one-line change reads as a large one.
- **[DIFF-39]** Where an `edit` review's editor exits with status 3, the system
  shall reopen the review in `diff` mode on the draft as the reviewer saved it,
  shown against nothing where the subject had no prior version, return that
  mode's verdict and comments, and carry any edit made before the switch in
  `editedFields`. The buffer shall name the status and the viewer it switches
  to, and shall offer the switch only where a viewer is named (CONFIG-15a). An
  edit review answers a draft that needs a small fix; a change the reviewer
  wants made rather than makes is a note, and the mode the subject picked has
  nowhere to leave one.
- **[DIFF-44]** Where an `edit` review opens in Helix or Vim, the system shall
  bind three chords for that review alone: `ZZ` to save and approve, `ZX` to
  exit 2 and reject, and `ZD` to save and exit 3 into `diff` mode (DIFF-39),
  keeping the reviewer's own configuration, and the buffer shall name each chord
  with the status it stands for while the editor's hints are on (CONFIG-21). An
  exit code typed at a prompt is an act nobody does by habit, so the three ways
  to end a review need keys as short as the save, and Vim's own `ZZ` sets the
  shape. The switch is D for `diff` rather than R, which a reviewer thinking
  "reject" reaches for.
- **[DIFF-45]** Where the reviewer edits a `--files` review's draft with
  revdiff's `e`, the system shall write the edit over the draft, return it as
  `editedFields`, and read an Accept of it as `changes-requested` (CONFIRM-08).
  revdiff shows that review in a scratch repo, whose copy of the draft is
  removed when the review closes, so the edit has to be carried out before then.
- **[DIFF-46]** Where a revdiff review carries a draft (a `--files` review, or a
  commit message) and an `edit` review could open, the system shall offer a
  third Verdict choice that relaunches the review in the user's editor, named by
  its command, and when chosen shall start the review over in `edit` mode on the
  draft as it stands, carrying the reviewer's other notes into the buffer's
  context. The choice names a relaunch of the review rather than an edit, so it
  doesn't read as editing the commit message, and it is the way back from the
  viewer that `ZD` (DIFF-44) is the way into it.
- **[DIFF-40]** Where a `diff` review's context file states what quitting does,
  the system shall put the change's size directly under the title, then, in a
  box drawn in solid lines, one key for each of the viewer's actions for the
  previous and next change, on one row, and for annotating a line and a file,
  read from the viewer's own bindings; and last, how to hide the keys; then the
  Verdict section (DIFF-42). A review round's and a batch's table shall carry the
  same box and Verdict section. Every terminal draws solid box lines joined. A
  reviewer coming back to a review cold reads how big it is first, a reviewer who
  knows the keys skips the box, and what each way of ending the review does has
  to stand apart from the prose around it. Where a reviewer's note sits on the context file, the system shall
  return it with its line and that line's text, since the file is gone once the
  review closes and a note on the keys or the size is not about the message.
- **[DIFF-41]** Where a review carries the agent's notes on its own changes
  (COMMIT-23), the system shall preload them where the tool shows preloaded
  notes and open the review without them otherwise, report which in the probe
  before the launch, keep the review's context file, and read a note returned as
  seeded, or deleted, as read. Notes that explain a change add to the review
  rather than define it, so a tool that can't show them still grades the change.
- **[DIFF-42]** Where a `diff` review's tool quits with the same status for a
  reviewer with nothing to say as for one who discarded what they said, the
  system shall put a Verdict section in the review's context file, or in the
  caller's table where it writes its own: an Accept line naming what approving
  does next, and a Reject line saying nothing the review gates happens. A note on
  the Accept line shall read as `approved`, with the reviewer's other notes
  carried as comments; a note on the Reject line as `rejected`; notes elsewhere
  and none on either line as `changes-requested`; and a review that leaves no
  note of the reviewer's, or a note on both lines, as `no-verdict` with
  `raw.exitCode` `undecided`, which the caller asks about (Accept, Reject, or
  reopen) rather than reading as approval or walking the fallback ladder. A
  review whose one note of the reviewer's says only `lgtm`, `ship it`,
  `approve`, or `accept` shall read as a note on the Accept line, and one saying
  only `reject`, `stop`, `abort`, or `cancel` as a note on the Reject line,
  wherever it sits except where a preloaded note sat, since there it answers
  that note; among other notes the word is one more note. In a review of items
  (a batch, a round), only a note on the shared table, off its rows, decides
  this way, and answers on the items' notes don't count as other notes, since a
  word on an item (a batch's `reject`) is about that item. A preloaded note
  returned as it was seeded is not a note of the reviewer's. The
  note that chose shall stay out of the notes a caller reads as items. The
  system shall unbind the tool's discard-and-quit key for the review, keeping the
  reviewer's other bindings, so the one way out is the quit that returns notes.
  revdiff exits 0 for `q` with no notes and for `Q`, which discards them, so
  without a written choice, quitting to get out reads as approval: it would
  publish every item of a batch, or approve a review whose notes were thrown
  away.
- **[DIFF-43]** Where the review tool shows a context file only beside a git
  diff, the system shall run a review of two files (`--files`) as a git diff in a
  scratch repository outside the user's checkout: the left side committed, the
  right side written over it under the reviewed object's reference where the
  caller passes one (DIFF-13a) and the right side's name otherwise, and the
  repository removed when the review closes. The right side is a temp file, and
  its random name says nothing about which issue or CR the reviewer is editing. The review then carries the same context file,
  keys, and Verdict section as any other (DIFF-36, DIFF-40, DIFF-42). A single drafted
  description, issue body, or release notes is what the reviewer sends out under
  their name, so it needs what approving does stated as much as a changeset does.

### CONFIG — Configuration

- **[CONFIG-01]** When drafting a commit, CR, or issue, the system shall read
  project and global `anchor.*` git config keys, matching the section and the
  setting case-insensitively and the qualifier exactly (CONFIG-20).
- **[CONFIG-02]** If an `anchor.*` key is absent, then the system shall keep its
  default and shall not invent a value.
- **[CONFIG-03]** Where the user mentions a ticket and `anchor.workTrackerBaseUri`
  is set, the system shall add a Refs trailer/link built from the base URI and
  id; with no mention, it shall add none.
- **[CONFIG-04]** Where `anchor.reviewBudgetMins` is set, the system shall let it
  steer how aggressively the description is trimmed, without changing the
  register.
- **[CONFIG-05]** Where `anchor.commit.rules`/`cr.rules`/`gitlab.rules`/`github.rules`/
  `issue.rules` are set, the system shall layer them onto the relevant defaults,
  preferring forge-specific overrides.
- **[CONFIG-06]** Where `anchor.watchPipelineAfterPush` or
  `anchor.<skill>.watchPipelineAfterPush` is set, the system shall gate the
  after-push pipeline watch on it, preferring the per-skill key; with neither
  set, it shall watch.
- **[CONFIG-07]** The system shall read `anchor.cr.verbosity` as an integer from 1
  to 100 setting where the CR description balances brevity against thoroughness
  — not a word budget, and never a truncation point — preferring
  `anchor.gitlab.verbosity`/`anchor.github.verbosity` for the forge in use; with none set,
  it shall draft at `25`.
- **[CONFIG-08]** When drafting at a verbosity below 100, the system shall shorten
  by abbreviating prose — asides, then explanation down to each section's
  load-bearing claim, then Review-guide clauses and tiers, then Context's second
  paragraph — and shall not remove a section on account of verbosity.
- **[CONFIG-09]** The system shall determine which sections a CR description
  contains from the template's conditions and `anchor.reviewBudgetMins` alone,
  and shall retain every such section at every verbosity, each abbreviated no
  further than its floor: one sentence of why for Context, the deep links for the
  Review guide.
- **[CONFIG-10]** The system shall let `anchor.cr.verbosity` steer length only,
  keeping the register unchanged, and shall resolve it independently of
  `anchor.reviewBudgetMins`, which steers what the description covers.
- **[CONFIG-11]** The system shall read `anchor.commit.verbosity` as an integer
  from 1 to 100 setting where the commit message body balances brevity against
  thoroughness; with none set, it shall draft at `50`. It shall shorten by
  abbreviating the body — asides, then the decision and alternatives prose, then
  the context paragraph — down to a floor of one sentence of why, and shall leave
  the subject line's format rules and the `Refs:` trailer untouched at every
  setting.
- **[CONFIG-12]** The system shall read `anchor.issue.verbosity` as an integer
  from 1 to 100 setting where the issue body balances brevity against
  thoroughness; with none set, it shall draft at `75`. It shall shorten by
  abbreviating prose — callouts, then the approach's explanation down to its
  load-bearing decisions, then Context's second paragraph — down to a floor of
  one sentence of why per section, and shall never drop or condense an acceptance
  criterion, which states what done means and is the issue's contract rather than
  its prose.
- **[CONFIG-13]** The system shall read `anchor.release.verbosity` as an integer
  from 1 to 100 setting where the release notes balance brevity against
  thoroughness; with none set, it shall draft at `10`. It shall shorten by
  abbreviating prose — rationale, then the consequences a user can infer, then
  each entry down to its floor of the change stated as its effect on someone
  using the project — and shall keep every entry and every breaking-change
  migration step at each setting.
- **[CONFIG-14]** The system shall apply every verbosity key to length alone —
  abbreviating a section rather than removing it, and keeping the register
  unchanged at every setting — and shall clamp an out-of-range or non-integer
  value into the 1–100 band, saying so once, rather than refusing to draft. The
  defaults shall descend along the lifecycle — issue, commit, CR, release — as
  each step widens the artifact's audience.
- **[CONFIG-15]** The system shall take a review's mode from its subject and
  shall offer no configuration key for it: `edit` where the subject is a single
  file with no prior version to compare against, `diff` everywhere else. Which
  shape fits is a property of the review rather than a preference — the question
  is whether it has a diff to show. Text against a blank left side marks every
  line as added and asks the reviewer to comment their way to a rewrite of a
  document an editor could have handed them, while real hunks — a left side with
  text in it, or a git range, which names a base by construction — are what
  per-hunk annotation is for. A key would only let a user ask for the shape that
  does not fit, and the shape the subject picked is still not a guarantee that it
  can open (DIFF-11). The subject rather than the invoking skill decides it, so
  one skill's review lands in whichever shape fits the review it is actually
  opening: a first draft and a revision of the same artifact are different
  subjects.
- **[CONFIG-15a]** The system shall make the tool that runs a mode configurable,
  one key per mode and symmetric between them: `anchor.edit.tool` names the
  editor, ranking above git's own chain (DIFF-16) as the narrower statement, and
  `anchor.diff.tool` names the viewer, falling through to git's own `diff.tool`.
  The tool is the half that is a preference, where the mode is not. **No viewer
  shall be assumed past those keys**: where neither names one, the system shall
  report that and name the keys that would, rather than selecting a viewer on the
  user's behalf. A recommended viewer is still only a recommendation — it reaches
  a review by being named, the same as any other — and a tool the user did not
  choose returns a verdict recorded as theirs, which is the one thing a review
  must not manufacture. A single key naming a mode and
  a tool together has nowhere to say *which* viewer and makes the editor's own name
  ride a second, parallel set of report fields; where such a superseded key is
  set, the system shall report that it no longer does anything and name the keys
  that replaced it, so a configuration written against the old shape is neither
  silently obeyed nor silently ignored.
- **[CONFIG-15b]** Where a consumer probes before launching (DIFF-17, DIFF-24), the
  system shall answer from the same subject the launch will carry, and the consumer
  shall pass it — the review's mode flag and, for a two-path review, both paths. A
  probe given no subject answers for a review nobody is about to open, which is the
  failure DIFF-24's same-`--skill` rule guards against one argument over.

- **[CONFIG-16]** The system shall name every configuration key
  `anchor.<qualifier>.<setting>`, the subsection stating what the setting is
  qualified by and the key stating what is set, and shall read an unqualified
  `anchor.<setting>` as the base that applies where no qualifier matches. One
  rule across every key is what lets a user predict a key they have not read
  about, and what leaves room for a qualifier the author did not anticipate — the
  destination a setting applies at had nowhere to go while a qualifier was
  spelled as a camelCase prefix on some settings and a subsection on others. The
  term is *qualifier* rather than *scope* because `git config --show-scope`
  already names the local / global / system layer a value was read from, and both
  appear in the same guidance.
- **[CONFIG-17]** Where several qualifiers match one setting, the system shall
  prefer the most specific — forge, then artifact type, then the base — and shall
  resolve each setting independently, so that a qualifier set for one setting does
  not imply that qualifier for another.
- **[CONFIG-18]** The system shall name the qualifier ahead of the setting and
  shall not accept the reverse. `git config` reads the final dot-separated
  segment as the key name, so the order is not interchangeable: a qualifier
  carrying a dot survives only at the tail of the subsection —
  `anchor.github.com.deny` resolves as written where `anchor.deny.github.com`
  parses as subsection `deny.github` and key `com` — and fixing the order for
  every key is what keeps a dotted qualifier addable later without moving the
  keys that already exist.
- **[CONFIG-19]** Where a key is set under a superseded name, the system shall
  report that it no longer does anything and shall name the key that replaced it,
  as CONFIG-15a requires, and shall not act on its value. It shall not carry the
  value to the replacement: the superseded `mrRules` / `prRules` were forge
  overrides of the CR rules alone, where `anchor.gitlab.*` / `anchor.github.*`
  qualify every artifact published to that forge, so a mechanical carry would
  apply a setting more widely than the user asked for. A rename that does not
  preserve meaning is not one the system may perform on the user's behalf.
- **[CONFIG-20]** The system shall spell every qualifier in lower case and shall
  match it exactly, `git config` holding a subsection case-sensitively where it
  folds the section and the key: with `anchor.CR.verbosity` set, a read of
  `anchor.cr.verbosity` finds nothing, where `anchor.commitverbosity` still
  answers for `anchor.commitVerbosity`. Where the system reads a key whose
  qualifier differs from a known one only by case, it shall report the key and
  the spelling that would be read, since the setting is otherwise inert and looks
  set.
- **[CONFIG-21]** The system shall read `anchor.hints` as a boolean,
  defaulting to `true`, with `anchor.diff.hints` and `anchor.edit.hints`
  overriding it for their mode (CONFIG-17). Where the value read for a mode is
  `false`, the system shall leave the review tool's keys out of every context
  that mode's review shows: a `diff` review's context file, a review round's and
  a batch's table (DIFF-40), and the editor keys in an `edit` review's buffer
  (DIFF-39), while keeping the Verdict section (DIFF-42). The keys help a
  reviewer new to the tool and repeat themselves on every review after that.

### FORGE — Forge integration & output

- **[FORGE-01]** Where the project ships a CR or issue template, the system shall
  compose into it — filling its sections, preserving reviewer-facing structure
  verbatim, and stripping author-facing scaffolding.
- **[FORGE-02]** If a GitHub issue template is a structured `.yml` form, then the
  system shall surface it for the author to fill in the web UI rather than
  compose prose into it.
- **[FORGE-03]** The system shall pass multi-line bodies to the forge by file
  (`--body-file` / `-F description=@`) rather than inline escaped strings.
- **[FORGE-04]** The system shall verify markdown rendering against the known forge
  gotchas before presenting a description or issue body.
- **[FORGE-05]** If a forge write fails with an auth error, then the system shall
  surface it and ask the user to refresh credentials rather than silently fall
  back to copy-only.
- **[FORGE-06]** Where a repo ships no CR template of its own, the system shall
  compose into the one it inherits from the forge — a GitLab parent group or the
  instance, or the owner's GitHub `.github` repo — and shall prefer a repo-local
  template over any inherited one.
- **[FORGE-07]** Where a level holds more than one CR template, the system shall
  select a `default.md` (case-insensitive), else the sole template, else ask the
  author which to compose into, rather than selecting by glob or API order.
- **[FORGE-08]** If a CR-template lookup returns nothing or is permission-denied,
  then the system shall fall through to the next level, and shall use its own
  default shape only when no level supplies a template.
- **[FORGE-09]** Where `anchor.cr.templateRepo` names a repo, the system shall read
  a CR template from it only after every forge-supplied level has declined.
- **[FORGE-10]** Where a CR description is composed into a template, the system
  shall replace or remove every placeholder the template leaves for the author
  (`TODO`, `TBD`, `FIXME`, `XXX`, an HTML comment, an angle-bracket prompt)
  before the description is presented for review.
- **[FORGE-11]** Where a CR template carries checkboxes that make claims about
  the change, the system shall tick each only when reachable evidence shows the
  claim true, leave it unticked when the evidence shows it false, and omit an
  item that no reachable evidence settles, naming the omitted items to the author.
- **[FORGE-12]** When a CR description is drafted or updated, the system shall
  re-derive every checkbox state from evidence and shall not carry over the state
  a box holds in the template or in the CR's existing description.

### EVENTS — Announcements to sibling plugins

- **[EVENTS-01]** The system shall publish each lifecycle fact it causes as one
  line on stdout, keyed `codes.bridgeai.anchor/<entity>.<event>` and carrying a
  compact JSON body, so a sibling plugin reading tool output can react to it.
- **[EVENTS-02]** The system shall announce only facts it caused, never one it
  observed a sibling cause.
- **[EVENTS-03]** The publisher shall exit 0 on every path, malformed calls
  included, so an announcement cannot turn an operation that succeeded into a
  tool call that failed.
- **[EVENTS-04]** The system shall build the body such that a field value
  carrying a space, a quote, a backslash, or a newline reaches the subscriber
  intact and leaves the announcement on one line.
- **[EVENTS-05]** The system shall declare every key it publishes in its
  manifest, with the condition that fires it, the source that emits it, and each
  field it carries.
- **[EVENTS-06]** The system shall announce a fact only after the operation it
  describes has landed.
- **[EVENTS-07]** Where a fact is caused by a script rather than by the model's
  judgment, the system shall announce it from that script, so a run whose skill
  does not reach the end still announces what it did.
- **[EVENTS-08]** A `/anchor:prepare-review` run shall announce `cr.created` or
  `cr.updated` and never both.
- **[EVENTS-09]** The system shall announce `commit.pushed` after the push
  rather than after the commit, and shall carry a commit web address naming the
  project as well as the sha, left empty where `origin` is not a forge it can
  address.
- **[EVENTS-10]** The system shall drop credentials embedded in the `origin`
  remote rather than carrying them into an announced address.
- **[EVENTS-11]** The system shall read a change request's draft flag at the
  moment it clears it, and shall announce `cr.ready` only where the flag moved.
- **[EVENTS-12]** The system shall route every path that clears a draft flag
  through one helper, so `cr.ready` has a single emission point and one shape
  whichever skill reached it.
- **[EVENTS-13]** The system shall carry the forge's own merge timestamp and
  landed commit in `cr.merged`, read back from the forge rather than assembled
  from what the run knows.
- **[EVENTS-14]** `cr.merged` shall cover merges the system performed; where the
  forge completes one on its own afterwards, the system shall not announce it.
- **[EVENTS-15]** The system shall announce `release.created` only once the forge
  reports the release exists, reading its address and tag back from the forge
  rather than from the version the run recommended.
- **[EVENTS-16]** Where the repo's release model publishes no forge release, the
  system shall announce nothing for the release.
- **[EVENTS-17]** The system shall announce `issue.created` on a create only,
  not on an update to an issue that already existed.

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
- **[RULE-04]** The system shall use `gh`/`glab` for mechanical and query forge
  operations, and route artifact *authoring* through the `anchor` skill — a CR
  description through `/anchor:prepare-review`, an issue through `/anchor:issue`,
  release notes through `/anchor:release` — rather than a bare `create` /
  `--body` / `--generate-notes`.
- **[RULE-04a]** The system shall not offer the CR-creation URL a push prints as
  the way to open a change request, and shall name `/anchor:prepare-review`
  instead. GitHub prints a `Create a pull request` link on a new branch's push
  and GitLab a `merge_requests/new` one, in output the system has just read; the
  form behind it lands the same CR a bare `create` would — non-draft, template
  checklist intact, no Review guide — with the drafting moved onto the user.
- **[RULE-05]** While deciding whether a history rewrite is safe, the system shall
  read push state and the CR draft flag fresh at the moment of the rewrite
  rather than from an earlier turn.

### UX — Interaction discipline

- **[UX-01]** The system shall not narrate its plumbing; it shall speak only
  when the user must act or decide.
- **[UX-01a]** Where the system reports a step that did not complete, it shall
  name what happened and what follows in terms the user can see — the editor
  closed, the viewer is not installed, the pane went away — and not in the
  vocabulary of its own internal guidance. Naming a numbered step of a fallback
  sequence describes a document the user has not read and obliges them to ask
  what the earlier steps were before they can answer.
- **[UX-02]** When a skill starts while a task is already in progress, the
  system shall run silently inside the orchestrator's task list and not create
  its own.
- **[UX-02a]** Where a skill creates its own task list, each task shall name
  the work it tracks and carry no step number. A task list covers a subset of a
  skill's numbered steps, so numbering it from the skill's headings shows the
  user gaps for steps they never see.
- **[UX-02b]** Before a skill calls a task tool, it shall establish from the
  session's tool listing that the task tools exist, and skip task tracking
  without comment when they don't. Claude Code withholds the task tools on some
  models, and a call made to find out prints a tool error under the skill's
  load line.
- **[UX-03]** The system shall present multi-way user decisions through
  `AskUserQuestion` with the recommended option first.
- **[UX-04]** The system shall not treat the output of a presentation command as
  having shown the user anything, and shall not ask for approval of an artifact it
  has emitted only as tool output — a drafted artifact under decision reaches the
  user as text in the reply or through a review tool.
- **[UX-05]** Where a helper script can supply a value the skill would otherwise
  derive with its own commands (a path hash, a temp path), the system shall read it
  from the recon block rather than run those commands.
- **[UX-06]** The system shall prescribe only commands whose shape and paths a
  caller can grant, shall name the allow rule that covers each prescribed path,
  and shall state the shells and platforms its prescribed commands assume. A
  path-scoped allow rule matches a literal prefix, so a `${TMPDIR:-/tmp}`
  template resolves outside an `Edit(//tmp/**)` grant on any platform that sets
  `TMPDIR` — macOS always among them; and a compound shape (`;`, `&&`, `$(…)`
  around the consequential step) is gated on the shape alone and cannot be
  approved by any permission entry. The cost lands in the caller's session on
  every run for as long as the guidance stands, and with several sessions open it
  is not the click but the prompt sitting unnoticed in a window nobody is
  watching.
- **[UX-06a]** The system's own scripts may honor `$TMPDIR` where its prescribed
  guidance may not. The safety analyzer reads the outer command line, so a
  `mktemp` inside `bash scripts/foo.sh` is invisible to it and a script is free
  to respect a per-user temp dir. Both positions are correct at once, and the
  reconciliation is stated where each is written rather than left as two files
  that disagree.
- **[UX-07]** When the system opens a review, it shall print, in the message that
  launches it, a manifest of what is under review — the change request it
  belongs to in its forge's short form (the repo and branch where there is
  none), its size (files and lines for a changeset, sections for a drafted
  document), the tool about to draw it, and what approving it sets off. A review tool renders one file or one buffer at a
  time and never shows the set, so a reviewer cannot tell from the tool whether
  the scope in front of them is the scope they asked for. Where the tool or
  the editor was one the system settled on rather than one the user configured,
  that message shall additionally name the configuration key that would choose
  it and the value producing what is on screen. A review opens in whatever the
  resolution ladder coalesced onto, and the tool it opens is the last place that
  would mention the preference exists — so the moment the user is looking at a
  choice they didn't make is the moment to say it is a choice. The hint shall
  stand only for the half that was defaulted, which retires it as soon as they
  set one. The rest of the launch
  stays silent under UX-01: the command, its flags, the tool resolution, and
  the wait are plumbing.
- **[UX-08]** Where a review returns the reviewer's own edits rather than
  annotations (DIFF-18), the system shall read each edit as either a fix or a
  note and act on it accordingly: a fix is already in the working tree and is
  kept, while a note the reviewer wrote in the file's comment syntax shall be
  answered and its lines removed before anything is committed. The separation is
  judgment and belongs to the model — the script can report what changed but not
  which kind of change it was — and the removal is not optional, since a question
  addressed to the author is a comment on the change rather than part of it and
  reaches the default branch if it survives. The system shall verify the removal
  against the files the reviewer touched before re-reviewing, since a line left
  behind is invisible in a diff already read once.
- **[UX-09]** Where the system seeds a review with notes (REVIEW-20, DIFF-37, a
  batch), it shall place each note on the line it concerns: the changed line it
  is about, or the line the reviewer's comment sat on. It shall put a note on a
  whole file only when the note concerns that file as a whole, or the resource
  the file stands for in a batch (an issue, a change request, a thread reply),
  and in the
  review's context file only when it concerns the commit message, the
  description, or the changeset as a whole. A note away from its code makes the
  reviewer leave the place they are reading to find what it means, where a note
  on the line reads like a comment in any other code review. So that a reviewer
  stepping from hunk to hunk reaches every note, the system shall show a note on
  a whole file on that file's first change, saying it concerns the whole file,
  and shall put a note further than a few lines from every change in the
  review's context file with the lines it concerns quoted, answered there on its
  item's row, rather than on code it isn't about. Either still posts where it
  concerns.
- **[UX-10]** Where a note's line is in a file the review would otherwise leave
  out, because nothing in it changed, the system shall put the note in the
  review's context file, quoting the lines it concerns with three lines either
  side and the concerned lines marked, rather than open the file. A file with no
  change opens in full, so the reviewer would scroll a whole file to find one
  note in it.
- **[UX-11]** When a review launches, the system shall open its manifest with a
  line saying where the review is on screen (a split of the session's pane, a popup
  or overlay over it, an editor window), from the host the probe reports, so a
  user returning to the session's pane knows where to look.
- **[UX-12]** Where the system shows the user a change it made, it shall carry
  the reasoning the user needs to judge the change as notes on the lines it
  concerns, gone when the review closes, and shall keep in a commit message, a
  CR description, or a code comment only what stays true beyond the review: why
  the change exists, or why the code is the way it is. Reasoning with no
  transient home lands in the permanent record, where it narrates a decision to
  readers who weren't there for it and makes the record long.

### CONFIRM — Approval before publishing

Everything the system publishes goes out under the user's credentials and in
their name, with nothing marking it as drafted by an agent. These requirements
govern what the user must have read before that happens.

- **[CONFIRM-01]** When the system has drafted prose it will publish under the
  user's identity — a commit message, a CR description, an issue body, a
  review-thread reply, or release notes — it shall obtain the user's approval of
  the exact text before publishing any of it.
- **[CONFIRM-02]** The system shall present the text for that approval as
  UX-04 requires: verbatim, in the reply or in a review tool, never as a
  paraphrase and never as the output of a command it ran.
- **[CONFIRM-03]** The system shall not treat approval of a plan, a disposition,
  or a shape as approval of the words that later fill it; each is a separate
  gate.
- **[CONFIRM-04]** Where several such artifacts are drafted in one round, the
  system shall gate them as one set rather than prompting per artifact.
- **[CONFIRM-05]** If the user does not approve a drafted artifact, then the
  system shall publish none of it and leave the target unchanged.
- **[CONFIRM-06]** Where the user revises the text at the gate, the system shall
  publish the revised text and shall re-present anything it changes afterward.
- **[CONFIRM-07]** Where the review tool shows the drafted text only on request or
  not at all (a diff viewer), the system shall print the text verbatim when it
  launches the review.
- **[CONFIRM-08]** If the reviewer writes on the drafted text inside the review
  tool, then the system shall not read the review as approval of the text as
  drafted.
- **[CONFIRM-09]** When a flow other than `/anchor:commit` commits on the user's
  behalf, the system shall review the commit's message and changeset as
  `/anchor:commit` does before committing it, once per round of feedback rather
  than once per fix.
- **[CONFIRM-10]** Where a flow drafts edits to two or more targets in one round
  (issue edits, thread replies), the system shall present the set for approval in
  a review tool, one file per item showing its current text against the proposed
  text, rather than in the reply, since a reply holding several drafts scrolls the
  first ones away before the question arrives.
- **[CONFIRM-11]** The system shall list the batch's items in a table the
  reviewer edits in the review, grouped under a heading for each kind of item
  (milestones, issues, change requests, replies), and shall carry context for
  the review in notes on the items, which it shall not publish.
- **[CONFIRM-12]** When a batch review closes, the system shall decide each
  item's outcome deterministically in a script: an item left as it was is kept,
  an item whose file the reviewer edited publishes their text verbatim, an item
  whose note is answered with a drop word (`drop`, `no`, `skip`) or whose row
  was deleted is dropped, one answered with a yes (`ok`, `lgtm`, 👍) is kept,
  and an item carrying any other new or edited note is redrafted into a further
  round. Kept and edited items publish only on an `approved` review (DIFF-42);
  on `changes-requested` every item not dropped goes into the further round.
- **[CONFIRM-13]** If a batch review does not complete, or is rejected, then the
  system shall publish none of its items, and shall not present the drafts in the reply as a
  substitute for the review.
- **[CONFIRM-14]** The system shall read a batch review's table and a review
  round's table by the same rules: a deleted row drops its item, and an edited
  row or a note on a row changes it.
- **[CONFIRM-15]** The system shall open a batch review's table and a review
  round's table by saying who opened the review and why, what each verdict does, and
  that the table is the review's guide rather than one of its items, and a
  round's table shall also name the repository and link the CR it reviews, so a
  reviewer coming back to a review they had forgotten can act on it without
  asking.
- **[CONFIRM-16]** Where a batch's items span more than one repository, the
  system shall name each item's repository in its path, below the directory for
  its kind (`issues/<repo>/<number>.md`), and shall refuse to lay out a batch whose
  paths leave one out or name the wrong one. Repositories number their issues
  and CRs independently, so a path that names only the number reads the same for
  two different items, and the reviewer has to open the link to learn which
  repository an edit lands in.
- **[CONFIRM-17]** The system shall write the Review status section (REVIEW-31)
  without asking for approval of its text. It holds the counts and verdicts the
  system records, not prose, and a prompt for it would come with every review
  round and every commit.

### SANITIZE — Sanitizing what reaches a destination

The system drafts prose from whatever the session holds, and a session working
one repo routinely holds another's hostnames, paths, and credentials. What is
unremarkable in the terminal is a disclosure once it publishes. These
requirements govern what the system removes before the CONFIRM gate sees it.

- **[SANITIZE-01]** When the system has drafted prose it will publish under the
  user's identity, it shall scan that prose against the artifact's destination
  before presenting it for the CONFIRM-01 approval, so that the text the user
  approves is the text that publishes.
- **[SANITIZE-02]** The system shall scan the staged diff alongside the drafted
  prose, on the same terms.
- **[SANITIZE-03]** The system shall determine what a scan finds
  deterministically in a script, and shall decide what stands in a finding's
  place in the skill: what is present is a fact, and what to say instead is
  judgment.
- **[SANITIZE-04]** The system shall find, with nothing configured: a hostname
  that is neither the destination's own nor a well-known public one; a credential
  shape — a token, a `user:pass@host` URL, a bearer string; an absolute local
  path carrying a user account name; and a link to a tracker the destination's
  readers cannot reach.
- **[SANITIZE-05]** The system shall read `anchor.deny` as terms that shall not
  appear at any destination and `anchor.<forge>.deny` as terms that shall not
  appear at one published to that forge, both multivalued, both matched as bare
  terms.
- **[SANITIZE-06]** The system shall read `anchor.allow` and `anchor.<forge>.allow`
  as terms a SANITIZE-04 finding shall not fire on. A rule that flags the public
  references a description is supposed to carry teaches the user to approve past
  the gate, which costs more than the findings it produces are worth.
- **[SANITIZE-07]** Where the system stands something in a finding's place, the
  replacement shall preserve the finding's shape — a hostname for a hostname, a
  path for a path — and shall read as a placeholder the reader can substitute
  their own value into. Prose naming what was removed leaves a technical sentence
  carrying an English clause where a token belongs, and the reader loses the
  shape they would have substituted into.
- **[SANITIZE-08]** If a shape-preserving replacement for a finding is not clear,
  then the system shall ask the user what to say rather than choosing one, and
  shall offer no configuration key carrying replacement text.
- **[SANITIZE-09]** The system shall present each substitution it made alongside
  the text at the approval gate, naming what was found and what stands in its
  place, so that the gate approves the substitutions and the prose together.
- **[SANITIZE-10]** If a finding is left neither replaced nor allowed, then the
  system shall publish none of the artifact, as CONFIRM-05 requires of one the
  user has not approved.
- **[SANITIZE-11]** The system shall carry a sanitization quality among the
  review qualities (REVIEW-15) so that a review weighs the same content again,
  and shall not let that quality stand in for the gate: a review runs once the
  commit message and the CR description have already published.
