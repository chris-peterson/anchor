# Forge cookbook

Canonical `gh` (GitHub) and `glab` (GitLab) invocations for the operations
`anchor`'s skills perform — creating and updating change requests (CRs: pull
requests on GitHub, merge requests on GitLab), filing issues, and posting
review comments. Both CLIs reason more reliably from explicit flags than from
guessing, so prefer these forms over re-deriving them.

Pick the CLI by the `origin` remote: a GitHub remote → `gh`; a GitLab remote →
`glab`. Both must be authenticated with read+write scope — `gh auth login` /
`glab auth login`.

When you run `glab` from **outside** a GitLab checkout — no `origin` to infer the
host from — target the host explicitly with `--hostname <host>`. That flag is
valid on **`glab api`** only; porcelain subcommands (`glab mr view`, `glab issue
view`, …) reject it with *"Unknown flag"*. So when you need to name the host,
reach for the `glab api` form of the operation rather than its porcelain
shorthand.

## Targeting a repo that isn't the working directory

Every form below defaults to the repo backing the current directory. When the
work targets a *different* repo — you're in repo A but operating on a CR in repo
B — retarget explicitly rather than relying on cwd (which files the operation
against the wrong project):

| Command form | How to retarget |
|---|---|
| `git …` | `git -C <path> …` |
| `gh` subcommand (`gh pr view`, `gh pr edit`, …) | `-R [HOST/]OWNER/REPO` |
| `glab` subcommand (`glab mr view`, …) | `-R OWNER/REPO` (full URL/Git URL also accepted) |
| `glab api projects/:fullpath/…` | **no `-R`** — substitute the URL-encoded project for `:fullpath` (e.g. `group%2Fproject`), plus `--hostname <host>` for self-hosted |

Derive `OWNER/REPO` and the host once from `git -C <path> remote get-url origin`.

**`anchor`'s helper scripts take `--repo <path>` (or `--worktree <path>`) instead.**
`prepare-review.sh`, `squash-check.sh`, `look-ahead.sh`, `review-diff.sh`, and
`pipeline-status.sh` `cd` into the given checkout for their (single-process) run,
so every git/`gh`/`glab` call inside them targets it with no per-command flag —
and `glab mr create` works because it runs *inside* the target checkout (passing
it `-R` is ignored and creates against the cwd repo → a `422` fork-mismatch).
Reach for the per-command flags above only for forge operations a skill runs
directly across separate Bash calls, where there's no persistent `cd`.

**When the work mutates a repo the session didn't start in, isolate it in a
worktree.** `${CLAUDE_PLUGIN_ROOT}/scripts/worktree.sh setup <target>` decides
direct-vs-isolated (by comparing the git common dir against the cwd repo) and,
for a *different* repo, adds a throwaway worktree on the target's current branch
so the work never disturbs that repo's own checkout; the skill threads the
resulting `CHECKOUT` through every command and runs
`${CLAUDE_PLUGIN_ROOT}/scripts/worktree.sh teardown <target> <worktree>` when the
flow ends. This is the "should I use a worktree?" boundary: operate
directly in your session's repo, isolate in a worktree once you've wandered
outside it.

## Resolving a named target repo

The forms above take a *path*. When the user instead names a target — "file this
against `logbook`", "open the MR in `customer-svc`" — resolve the name through
tack's repo db rather than guessing from cwd or improvising a `-R` slug:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-target.sh" <name>
```

It prints `TARGET_VIA`:

- **`tack`** — one match, with `TARGET_URL`, `TARGET_FORGE`, `TARGET_HOST`,
  `TARGET_PROJECT`, `TARGET_LOCAL`. Use `TARGET_PROJECT` / `TARGET_HOST` with the
  per-command forms above (`gh -R`, `glab :fullpath` + `--hostname`), and
  `TARGET_LOCAL` as the checkout for anything needing a work tree.
- **`ambiguous`** — `TARGET_CANDIDATES` (`[{key,url,local}]`); prompt the user.
- **`cwd`** — no tack on PATH, or no match; fall back to the cwd `origin`.

**Local vs remote-only.** `TARGET_LOCAL` is empty for a known remote with no
checkout (the common case for a repo you don't have cloned). Pure-remote
operations — filing/updating an issue, describing or querying a CR — work fine
remote-only via `-R` / `:fullpath`. Operations that need a work tree — committing,
pushing, opening a CR (there must be a branch to push) — require a checkout: feed
`TARGET_LOCAL` into the worktree lifecycle above when present, and when it's empty
ask for an explicit `--repo <path>` rather than proceeding. tack is optional —
without it (or with no match) `TARGET_VIA=cwd` and everything behaves as today.

## Linking an ordering dependency between CRs

When one CR must land *after* another (a shared library before its consumer; a
config that points at the consumer), record the ordering on the forge — not only
in prose — so the two can't merge out of order.

**GitLab — a real, enforced dependency** (Premium/Ultimate; the `/blocks`
sub-resource, GitLab ≥ 17.5). Mark the dependent MR blocked by its predecessor:

```bash
glab api -X POST "projects/:fullpath/merge_requests/<iid>/blocks" \
  -F blocking_merge_request_iid=<predecessor-iid> \
  -F blocking_project_id=<predecessor-project-id>   # omit when same project
```

Related endpoints: `GET …/merge_requests/<iid>/blocks` (what this MR waits on),
`GET …/merge_requests/<iid>/blockees` (what waits on it), `DELETE
…/merge_requests/<iid>/blocks/<block_id>`. Use the `glab api` form (there's no
`glab mr` porcelain verb for blocks); add `--hostname <host>` for a non-cwd or
self-hosted instance.

**Detect-by-attempt, degrade cleanly** — don't pre-probe the tier/version, just
read the status:

| Status | Meaning | Do |
|---|---|---|
| `201` | dependency created | done |
| `409` | already linked | treat as success |
| `404` | instance predates the `/blocks` API (< 17.5) | fall back to the prose reference |
| `403` | not Premium/Ultimate, or no permission | fall back to the prose reference |

**GitHub — no native cross-PR dependency exists.** There's nothing to set; the
ordering lives in the description as a prose reference, which the forge does *not*
enforce. (GitHub has "blocked by" for issues, not PRs.)

**The prose reference (both forges, always when a dependency exists).** Add a line
to the description: `Depends on !<iid>` (GitLab) / `Depends on #<num>` (GitHub) —
bare, so it autolinks — and say it must merge first. On GitLab this *complements*
the enforced block; on GitHub (or a GitLab fall-back) it's the only signal, so say
plainly that ordering isn't enforced.

## Defaults `anchor` applies

When `anchor` creates a CR or an issue on your behalf, it applies these defaults.
They reflect a single-maintainer-friendly workflow; adjust per project as
needed.

| Default | GitHub | GitLab |
|---|---|---|
| **Create CRs as draft** | `gh pr create --draft` | `glab mr create --draft` |
| **Assign to yourself** | `--assignee @me` | `--assignee <username>` (see below) |
| **Delete source branch after merge** | no per-PR field — the repo-wide `deleteBranchOnMerge`, plus `--delete-branch` at merge | `glab mr create --remove-source-branch` |
| **Assign issues to yourself** | `gh issue create --assignee @me` | `glab issue update <iid> --assignee <username>` after an API-form create |

GitLab has no `@me` shorthand. Capture your username once and reuse it
(`glab` has no `--jq` flag, so pipe to `jq`):

```bash
glab api user | jq -r '.username'
# → chris
```

**`glab api` has no `key[]=value` array syntax** (unlike `gh api`): a flat
`-F "assignee_ids[]=122"` goes up as a literal key GitLab silently ignores —
no error, the MR or issue just lands unassigned. For array-valued fields,
either run a follow-up command that takes usernames (`glab mr update <iid>
--assignee <username>`, `glab issue update <iid> --assignee <username>`) or
pass a JSON body via `--input` (the same trap exists for nested objects —
see the line-anchored discussion section).

## Multi-line bodies: write a file, pass it with -F / --body-file

For any body with tables, code blocks, or fenced content, write it to a temp
file and reference the file — no command substitution, no escape gymnastics.

Pick the path with `mktemp -u` — `-u` prints a unique name *without* creating
the file, so a follow-up `Write` treats it as fresh, and a random name won't
clobber a parallel session that hardcodes the same path. Keep the `XXXXXX`
**trailing** and append the suffix *outside* the template: BSD/macOS mktemp only
replaces a trailing run, so it takes `cr-body.XXXXXX.md` as a literal filename
(creating `cr-body.XXXXXX.md` verbatim, then colliding on it the next run —
`mkstemp failed … File exists`), whereas `$(mktemp -u …XXXXXX).md` behaves the
same on GNU, BSD, and Git Bash:

```bash
echo "$(mktemp -u /tmp/cr-body.XXXXXX).md"
# → /tmp/cr-body.aB3xKp.md
```

The `/tmp` is literal rather than `${TMPDIR:-/tmp}`: a caller grants paths by
prefix, and on macOS `TMPDIR` is always set, so the template resolves to
`/var/folders/…` and misses an `Edit(//tmp/**)` grant. See
[temp-paths](/guides/temp-paths) for the platform table, the allow rules to pair
with it, and why anchor's own scripts honor `$TMPDIR` where this guidance does
not.

Run inner commands (like the `glab api user` id lookup) as their own step and
reuse the captured value — chaining with `$(…)` or `;`/`&&` trips structural
safety gates in some agents and prompts unnecessarily.

## Forge autolink traps

For the renderer-general markdown gotchas — character escaping, nested code
fences, mermaid, collapsible `<details>`, tables in lists — see the bundled
`markdown-gotchas.md`. This section covers the forge-specific autolink trap:
output that links the wrong target, invisible in the markdown source until
rendered.

**Cross-project references need the full URL.** The `#NNNN` (issue), `!NNNN`
(MR), and `@name` (user) shortcuts resolve *within the current project*. In an
MR, a bare `#1234` autolinks to issue 1234 of that MR's project — not to a
same-numbered item in another project. CI/deploy pipelines routinely live in a
different project than the MR, so any reference to a pipeline, issue, or CR
outside the current project must use the full URL. The bare shortcut silently
links the wrong thing.

## PR create (GitHub)

```bash
# 1. Write the body to a unique temp path (see above).
# 2. Create the draft PR, assigned to you.
gh pr create \
  --draft \
  --title "PR title" \
  --body-file /tmp/cr-body.aB3xKp.md \
  --assignee @me
```

**GitHub has no per-PR branch-deletion preference** — `gh pr create` exposes no
flag for it and the PR object carries no field, so the create call can't set what
`glab mr create --remove-source-branch` sets on an MR. The standing setting is
repo-wide:

```bash
gh repo view --json deleteBranchOnMerge     # read it
gh repo edit --delete-branch-on-merge       # turn it on — every PR in the repo, needs admin
```

With it off, the branch survives any merge that doesn't pass `--delete-branch`
(the web UI, a bare `gh pr merge`, auto-merge). `/anchor:prepare-review` reports
the setting as `DELETE_BRANCH_ON_MERGE` and offers the repo edit; `/anchor:merge`
passes `--delete-branch` regardless.

## MR create (GitLab)

`glab mr create -d` only accepts a `<string>` (or opens an interactive editor —
undriveable from an agent), so use the API form for a file-sourced body:

```bash
# 1. Capture your username and the current branch.
glab api user | jq -r '.username'    # → chris
git branch --show-current            # → my-feature-branch

# 2. Write the body to a unique temp path, then POST the MR.
#    (No assignee here — glab api can't encode array fields; see the note
#    under "Defaults `anchor` applies".)
glab api -X POST projects/:fullpath/merge_requests \
  -F title="MR title" \
  -F "description=@/tmp/cr-body.aB3xKp.md" \
  -F source_branch="my-feature-branch" \
  -F target_branch="main" \
  -F remove_source_branch=true \
  -F draft=true

# 3. Assign it to yourself (capture <iid> from step 2's response).
glab mr update <iid> --assignee chris
```

To set branch deletion on an MR that was opened without it, use the API form —
`glab mr update --remove-source-branch` is documented as a *toggle*, so on an MR
that already has the flag it turns it off:

```bash
glab api -X PUT projects/:fullpath/merge_requests/<iid> -F remove_source_branch=true
```

Reading it back: the MR object carries `should_remove_source_branch` (what the
create/update set) and `force_remove_source_branch` (the project forcing it for
every MR) — either one true means the branch goes.

## Resolving the CR template a project inherits

The forges disagree about where an inherited template lives, and neither puts it
where a namespace walk would look.

**GitLab resolves the hierarchy for you.** One endpoint answers with every
template the project may use — its own, its parent group's, and the instance's:

```bash
glab api projects/:fullpath/templates/merge_requests            # [{key, name}, …]
glab api "projects/:fullpath/templates/merge_requests/<name>"   # {name, content}
```

Group templates live in a single **file-template project** the group designates
(a direct child of the group, Premium and up) — *not* in each ancestor's own
`.gitlab/merge_request_templates/`, so reading ancestors finds nothing. Two
things to know about the listing: the name is a path segment and template names
carry spaces (`Merge Request`), so percent-encode it; and the file-template
project itself lists its templates **twice** (once as its own, once as the
group's), so dedupe by name before counting.

Above every file source sits the project's own default-description-template
setting, which GitLab ranks first:

```bash
glab api projects/:fullpath | jq -r '.merge_requests_template'
```

**GitHub has no hierarchy** — one `.github` repo under the same owner, and it
must be public. There's no resolved-template endpoint, so read the file
directly, trying `.github/` then the root then `docs/` (the order GitHub itself
searches). The raw `Accept` header returns the body without the contents API's
base64, whose decode flag differs between GNU and BSD `base64`:

```bash
gh repo view --json owner --jq '.owner.login'
gh api "repos/<owner>/.github/contents/.github/pull_request_template.md" \
  -H "Accept: application/vnd.github.raw"
```

GitHub honors a template at six repo-local paths, not two:
`pull_request_template.md` under `.github/`, the root, or `docs/`, and a
`PULL_REQUEST_TEMPLATE/` directory in any of the three. GitHub has no
`default.md` convention for that directory — the author picks via a `?template=`
query parameter — while GitLab's `Default.md` is real and case-insensitive.

A level that 403s is a miss, not an error: permissions on an ancestor or the
instance are routinely tighter than on the project, so fall through to the next
level rather than failing the run.

## CR description update from a file

Editing the body of an existing CR.

```bash
# GitHub
gh pr edit <num> --body-file /tmp/cr-body.aB3xKp.md

# GitLab — `glab mr update -d` doesn't accept a file; use the API form.
glab api -X PUT projects/:fullpath/merge_requests/<iid> \
  -F "description=@/tmp/cr-body.aB3xKp.md"
```

## Check a CR's mergeable state

Before merging, read whether the forge considers the CR landable — conflicts or a
behind-base branch make the merge fail (or require a rebase first, which
`/anchor:prepare-review` owns).

```bash
# GitHub — mergeable is MERGEABLE / CONFLICTING / UNKNOWN;
# mergeStateStatus is CLEAN / BLOCKED / BEHIND / DIRTY / UNSTABLE / DRAFT / HAS_HOOKS.
gh pr view <num> --json mergeable,mergeStateStatus

# GitLab — detailed_merge_status is the single summarizing field (newer GitLab);
# merge_status (mergeable / cannot_be_merged) is the older fallback.
glab mr view <iid> --output json | jq '{detailed_merge_status, merge_status}'
```

GitLab's `detailed_merge_status` folds several gates into one value: `mergeable`,
`conflict` / `need_rebase` (not landable — rebase first), and the gate-not-met
states `not_approved`, `ci_still_running`, `ci_must_pass`, `discussions_not_resolved`,
`draft_status` (which the approval / pipeline / thread / draft checks below read
individually). On GitHub, `mergeStateStatus` of `BEHIND` means rebase-first,
`DIRTY` means conflicts, `BLOCKED` means a required gate (review/checks) isn't met.

## Check a CR's approvals

```bash
# GitHub — reviewDecision is APPROVED / REVIEW_REQUIRED / CHANGES_REQUESTED,
# or null when the repo requires no reviews (nothing to satisfy).
gh pr view <num> --json reviewDecision --jq '.reviewDecision'

# GitLab — the approvals sub-resource: approved (bool), approvals_required,
# approvals_left (0 when satisfied), approved_by[].
glab api "projects/:fullpath/merge_requests/<iid>/approvals" \
  | jq '{approved, approvals_required, approvals_left, by: [.approved_by[].user.username]}'
```

A GitHub `reviewDecision` of `null` and a GitLab `approvals_required` of `0` both
mean the repo has no approval rules — there's nothing to satisfy, so don't invent a
requirement.

## Merge a CR

Land an open CR into its target branch. Delete the source branch as part of the
merge (`--delete-branch` / `--remove-source-branch`) — on GitHub this is the only
place the branch gets cleaned up unless the repo-wide setting is on, and on GitLab
it repeats what the create call set. Guard the merge on the head SHA so a commit
that landed after you last looked can't sneak in unreviewed
(`--match-head-commit` / `--sha`).

```bash
# GitHub — pick exactly one strategy flag.
gh pr merge <num> --merge  --delete-branch --match-head-commit <sha>   # preserve commits
gh pr merge <num> --squash --delete-branch --match-head-commit <sha>   # squash into one
gh pr merge <num> --rebase --delete-branch --match-head-commit <sha>   # rebase, no merge commit

# GitLab — no --squash/--rebase flag means the project's configured merge method
# (merge commit / semi-linear / fast-forward). --yes skips the confirm prompt.
# glab enables auto-merge when a pipeline is running, so pass --auto-merge=false
# to merge immediately (the pipeline gate is already checked before this point).
glab mr merge <iid> --remove-source-branch --sha <sha> --yes --auto-merge=false          # preserve
glab mr merge <iid> --squash --remove-source-branch --sha <sha> --yes --auto-merge=false # squash
```

**Which strategies a repo allows.** GitHub enables merge/squash/rebase per repo
setting; a disabled strategy rejects the merge. Read them before offering a choice:

```bash
gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed
```

On GitLab the merge method (merge commit vs. semi-linear vs. fast-forward) is a
project setting, not a per-merge flag — `glab mr merge` follows it; `--squash` /
`--rebase` are the only per-merge overrides:

```bash
glab api projects/:fullpath | jq '{merge_method, squash_option}'
```

`merge_method` is `merge` / `rebase_merge` (semi-linear) / `ff` (fast-forward);
`squash_option` (`never` / `always` / `default_on` / `default_off`) says whether
squash is offered and its default. For `default_on` / `default_off` the author's
per-MR checkbox decides — read the MR's `squash` field to see which way it's set:

```bash
glab mr view <iid> --output json | jq '{squash}'
```

## Publish a release

Creating a release is the publish step for the `release-triggered` and
`tag-triggered` models (see `guides/release-models.md`). Pass the notes by file —
they are multi-line prose, and the body is what a release-triggered workflow
proxies into the changelog verbatim:

```bash
# GitHub — creates the tag from the default branch's tip if it doesn't exist;
# --target points that elsewhere, --verify-tag instead aborts unless the tag is
# already pushed. Never --generate-notes: a generated body lands a list of
# unrelated prior PRs in the changelog section a release workflow writes.
gh release create v<X.Y.Z> --title "v<X.Y.Z>" --notes-file <path>

# --target takes a branch name or a FULL 40-char sha. An abbreviated sha is
# rejected, and the 422 reads as a bad tag rather than a bad target:
#   tag_name is not a valid tag
#   Published releases must have a valid tag
#   Release.target_commitish is invalid
gh release create v<X.Y.Z> --title "v<X.Y.Z>" --notes-file <path> --target <full-sha>

# GitLab — same default (tags the default branch's tip when the tag is missing);
# --ref points it at a specific commit, tag, or branch instead.
glab release create v<X.Y.Z> --notes-file <path>
glab release create v<X.Y.Z> --notes-file <path> --ref <sha>
```

**Check the token can write releases before drafting.** Pushing over SSH needs no
forge token at all, so a token missing `Contents: write` (GitHub) or the
equivalent scope fails only at the create:

```bash
gh auth status                      # scopes the token carries
glab auth status
```

**Confirm what the last release actually was**, rather than inferring it from
tags alone — a tag can exist with no release attached:

```bash
gh release view --json tagName,publishedAt,isDraft
glab release list --per-page 5
```

## Issue list

Listing/ranking issues (the `issues` skill). Fetch as JSON and rank client-side —
neither CLI sorts by two keys in one pass.

```bash
# GitHub — assigned to me, open
gh issue list --assignee "@me" --state open --limit 50 \
  --json number,title,url,state,updatedAt,createdAt,milestone,labels,assignees

# GitLab — assigned to me (open is glab's default; --closed / --all widen it)
glab issue list --assignee=@me --output json --per-page 50
```

Filter flags:

| | GitHub | GitLab |
|--|--------|--------|
| **Unassigned** | `--search "no:assignee"` | *(no direct flag; use `--not-assignee <user>` or filter the JSON)* |
| **By assignee** | `--assignee <login>` | `--assignee <username>` |
| **By label** | `--label <name>` (repeatable) | `--label <name>` (comma-sep or repeatable) |
| **Include closed** | `--state all` (or `--state closed`) | `--all` (or `--closed`) |
| **By author** | `--author <login>` | `--author <username>` |

Known gaps:

- **No per-issue due date on GitHub.** Only milestones carry `dueOn` (via
  `--json milestone`); an issue's "due" is its milestone's due date, or absent.
  GitLab issues have a native `due_date`.
- **`glab` has no clean "unassigned" filter.** `--not-assignee` excludes a named
  user; a true "no assignee" view means filtering the JSON (`.assignees | length == 0`).
- **Compound rank isn't a CLI flag.** `glab --order` takes one field; `gh` sorts
  only via `--search "sort:…"`. For "due, then updated," rank locally with a
  stable two-pass sort — sort by the secondary key, then the primary:
  `jq 'sort_by(.updatedAt) | reverse | sort_by(.milestone.dueOn // "9999-12-31")'`
  (GitHub) / `jq 'sort_by(.updated_at) | reverse | sort_by(.due_date // "9999-12-31")'`
  (GitLab). The far-future sentinel sorts undated issues last.

## Issue create

```bash
# GitHub
gh issue create \
  --title "Issue title" \
  --body-file /tmp/issue-body.aB3xKp.md \
  --assignee @me

# GitLab (API form so the body can come from a file; assignee is a
# follow-up — glab api can't encode array fields)
glab api -X POST projects/:fullpath/issues \
  -F title="Issue title" \
  -F "description=@/tmp/issue-body.aB3xKp.md"

glab issue update <iid> --assignee <username>
```

## Issue description update from a file

Editing the body of an existing issue. To diff a new draft against what's live,
fetch the current body first (`gh issue view <num> --json body --jq '.body'`;
`glab issue view <iid> --output json | jq -r '.description'`).

```bash
# GitHub
gh issue edit <num> --body-file /tmp/issue-body.aB3xKp.md

# GitLab — the API form takes a file (the porcelain `glab issue update` does not).
glab api -X PUT projects/:fullpath/issues/<iid> \
  -F "description=@/tmp/issue-body.aB3xKp.md"
```

## Labels and milestones

Applied to an issue when it's filed or updated (the `issue` skill), and to a CR
once its description lands (`prepare-review`). Read the sets first — both CLIs
take a **name**, so a value that isn't in the project's set is either an error or
a brand-new label nobody asked for.

```bash
# GitHub — labels, then milestones
gh label list --limit 100 --json name,description
gh api 'repos/{owner}/{repo}/milestones?state=open&per_page=50' \
  --jq '.[] | "\(.title)\t\(.due_on)\t\(.description)"'

# GitLab
glab label list --output json
glab milestone list --state active --output json
```

Applying them:

| | GitHub | GitLab |
|--|--------|--------|
| **Issue, on create** | `--label <name>` (repeatable), `--milestone <title>` | `--label a,b` / `-m <title>` on `glab issue create`; from the API form, `-F labels=a,b` — but the milestone wants a numeric `milestone_id`, so set it in the `glab issue update` follow-up |
| **Issue, on edit** | `--add-label <name>` / `--remove-label <name>`; `--milestone <title>` replaces, `--remove-milestone` clears | `--label a,b` adds, `--unlabel a,b` removes; `-m <title>` sets, `-m ""` clears |
| **CR** | `gh pr edit <num> --add-label <name> --milestone <title>` (same flag split as `issue edit`) | `glab mr update <iid> --label a,b --milestone <title>` (`--label` adds, `--unlabel` removes) |
| **Read what's set** | `gh issue view <num> --json labels,milestone` · `gh pr view <num> --json labels,milestone` | `glab issue view <iid> --output json` / `glab mr view <iid> --output json` (`.labels`, `.milestone`) |

Known gaps:

- **`gh` has no `milestone` command.** The list comes from the REST API
  (`gh api repos/{owner}/{repo}/milestones`); `--milestone` on `create`/`edit`
  still takes the title, not the number.
- **`gh issue edit` has no `--label`.** It's `--add-label` / `--remove-label`
  there, while `create` uses `--label` — the same word means different things on
  the two subcommands.
- **GitLab milestones can be group-level.** `glab milestone list` returns the
  project's own; `--group <path> --include-ancestors` reaches the ones a project
  inherits, which is where a release milestone usually lives in a group.
- **The GitLab issues API can't take the milestone by title.** `POST
  projects/:fullpath/issues` wants `milestone_id`, so `anchor` sets labels and
  milestone in the `glab issue update <iid>` call it already makes for the
  assignee.

## Issue / CR comment from a file

`glab issue note` / `glab mr note` only accept `-m <string>` or open an editor.
Use the API form for a file-sourced comment:

```bash
glab api -X POST "projects/:fullpath/merge_requests/<iid>/notes" \
  -F "body=@/tmp/comment.aB3xKp.md"
```

`gh` accepts a file directly: `gh pr comment <num> --body-file <path>`.

## Fetch a CR's head without checking it out

Both forges publish every CR head under a read-only ref namespace on `origin`,
so reviewing someone else's change needs no extra remote, no branch checkout,
and works when the CR came from a fork:

```bash
git fetch origin "+refs/pull/<num>/head:refs/anchor-review/<num>"            # GitHub
git fetch origin "+refs/merge-requests/<iid>/head:refs/anchor-review/<iid>"  # GitLab
```

Diff it with the three-dot form against the base the forge reports
(`baseRefOid` / `diff_refs.base_sha`), which resolves the merge base rather than
mixing in commits that landed on the target branch since.

## Line-anchored MR discussion (GitLab)

`glab mr note` posts a general discussion. To anchor a comment to a specific
line of the diff, hit the discussions endpoint with a nested `position` object.
Flat `-F "position[...]=..."` is silently dropped (the note posts unanchored) —
build a JSON file and pass it via `--input`.

```bash
# 1. Get the MR's diff_refs (the SHAs the position pins to).
glab api projects/:fullpath/merge_requests/<iid> | jq '.diff_refs'
# → {"base_sha":"…","head_sha":"…","start_sha":"…"}

# 2. Write the payload (use new_line for additions; include old_line for
#    modified/deleted lines), then POST with an explicit Content-Type.
cat > /tmp/discussion.xY1mP3.json <<'EOF'
{
  "body": "…",
  "position": {
    "position_type": "text",
    "base_sha":  "<diff_refs.base_sha>",
    "start_sha": "<diff_refs.start_sha>",
    "head_sha":  "<diff_refs.head_sha>",
    "new_path":  "path/to/file.ext",
    "new_line":  42
  }
}
EOF

glab api -X POST projects/:fullpath/merge_requests/<iid>/discussions \
  --input /tmp/discussion.xY1mP3.json \
  -H "Content-Type: application/json"
```

Verify the returned note is `"type": "DiffNote"` with a populated `position` —
a `DiscussionNote` with `position: null` means the position was dropped and the
comment landed unanchored.

## Line-anchored PR review comment (GitHub)

The counterpart to the GitLab form above: `line` plus `side` replace GitLab's
`position` object, and `commit_id` carries the SHA the anchor pins to. `body`,
`commit_id`, and `path` are required; `position` still exists but is deprecated
in favor of `line`.

```bash
gh api -X POST "repos/<owner>/<repo>/pulls/<num>/comments" \
  -F "body=@/tmp/finding.aB3xKp.md" \
  -f "commit_id=<head-sha>" -f "path=path/to/file.ext" \
  -F "line=42" -f "side=RIGHT"          # RIGHT = the new side, LEFT = the old
```

For a range, add `-F "start_line=<first>" -f "start_side=RIGHT"`; `line` is then
the *last* line of the range.

## Batch a whole review into one notification (GitHub)

Posting N comments individually sends the author N notifications. The reviews
endpoint takes them as one submission instead — its `body` becomes the review's
summary, and `event: COMMENT` leaves comments without recording an approval or a
change request. **Omitting `event` is not the same thing**: it leaves the review
`PENDING`, visible only to its author until separately submitted.

```bash
cat > /tmp/review.xY1mP3.json <<'EOF'
{
  "commit_id": "<head-sha>",
  "body": "the summary that leads the review",
  "event": "COMMENT",
  "comments": [
    {"path": "src/cache.js", "line": 42, "side": "RIGHT", "body": "…"}
  ]
}
EOF

gh api -X POST "repos/<owner>/<repo>/pulls/<num>/reviews" --input /tmp/review.xY1mP3.json
```

GitLab has no batch equivalent — each thread is its own POST to `discussions`.

## File-level comments: why `anchor` doesn't use them

Both forges accept a comment scoped to a whole file rather than a line, and the
two are not equally specified: GitHub documents `subject_type: file` (with `line`
then not required), while GitLab lists `file` among `position_type`'s allowed
values without saying what the rest of the position must hold. Using one and not
the other would make the same review render differently depending on where the
CR lives, so `/anchor:review` anchors to lines and routes everything else into
the summary comment.

## List unresolved review threads

```bash
# GitLab — unresolved, human-authored discussions with their notes
glab api "projects/:fullpath/merge_requests/<iid>/discussions?per_page=100" \
  | jq '[.[] | select(.notes[0].system == false)
             | select([.notes[] | .resolvable and (.resolved | not)] | any)]'
```

Each discussion carries `id` (needed for replies/resolution), `notes[]`
(`author.username`, `body`), and — for line-anchored `DiffNote`s — a
`position` (`new_path`, `new_line`, `old_line`).

```bash
# GitHub — review threads with resolution state (REST doesn't expose it; use GraphQL)
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:100){nodes{id isResolved path line
      comments(first:50){nodes{author{login} body databaseId}}}}}}}' \
  -f owner=<owner> -f repo=<repo> -F pr=<num> \
  | jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved | not))'
```

## Reply to a review thread

```bash
# GitLab — POST a note into the existing discussion (body from a file)
glab api -X POST \
  "projects/:fullpath/merge_requests/<iid>/discussions/<discussion-id>/notes" \
  -F "body=@/tmp/reply.aB3xKp.md"

# GitHub — reply to a review comment by its databaseId
gh api -X POST "repos/<owner>/<repo>/pulls/<num>/comments/<comment-id>/replies" \
  -F "body=@/tmp/reply.aB3xKp.md"
```

## Resolve / unresolve a review thread

```bash
# GitLab
glab api -X PUT \
  "projects/:fullpath/merge_requests/<iid>/discussions/<discussion-id>" \
  -F resolved=true        # false to unresolve

# GitHub — GraphQL mutation on the thread id from the listing query
gh api graphql -f query='mutation($id:ID!){
  resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' \
  -f id=<thread-id>
```

## CI / pipelines

A commit's CI run goes by different names per forge: GitHub calls it a
**workflow run** (the *Actions* tab), GitLab a **pipeline**. `anchor` uses
**pipeline** as the generic term for both — pick `gh run` on a GitHub origin,
`glab` (the pipelines API) on a GitLab one. The `/anchor:pipeline` skill and its
`${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-status.sh` helper wrap the invocations
below; reach for them directly when scripting a one-off.

**Find the pipeline for a commit — ask by SHA, not by ref.** A run fired by a
published release or a pushed tag carries the *tag* as its branch, so
`--branch main` / `?ref=main` misses it even though the run is for that commit.
Both forges filter by commit directly:

```bash
# GitHub — every run for the commit, whatever ref triggered it.
gh api "repos/{owner}/{repo}/actions/runs?head_sha=<sha>&per_page=100" \
  | jq -c '.workflow_runs[] | {id, name, path, status, conclusion, html_url}'

# GitLab — the pipelines API filters by sha.
glab api "projects/:fullpath/pipelines?sha=<sha>&per_page=1" \
  | jq '.[0]'   # → {id, status, web_url, sha, ...}
```

**GitHub answers with one run per workflow.** There is no single "the pipeline"
for a commit: a push that triggers lint, test, and docs workflows produces three
runs, and a release adds a fourth on the same commit. Picking the most recent
one reports whichever finished last, so scope to the workflow you mean —
`/actions/workflows/<file>/runs?head_sha=<sha>` — or fold the runs into one
verdict (each workflow's latest attempt, then the worst state wins), which is
what `pipeline-status.sh` does.

**State vocabularies differ.** GitLab's pipeline `status` is a single field
(`success` / `failed` / `canceled` / `skipped` / `manual` are terminal;
`running` / `pending` / `created` / etc. are in flight). GitHub splits it: a run
is in flight until `status == "completed"`, then `conclusion` carries the
outcome (`success`, `failure`, `cancelled`, `timed_out`, `skipped`,
`action_required`, …). Normalize before comparing across forges.

**Failed jobs in a pipeline.**

```bash
# GitHub
gh run view <run-id> --json jobs \
  | jq -c '[ .jobs[] | select(.conclusion == "failure") | {name, url} ]'

# GitLab
glab api "projects/:fullpath/pipelines/<pipeline-id>/jobs?per_page=100" \
  | jq -c '[ .[] | select(.status == "failed") | {name, stage, url: .web_url} ]'
```

**One named job in a pipeline.** To poll a single gating job (a Terraform plan
job that the rest of the pipeline waits on, say) rather than the whole pipeline,
filter the same jobs list by name. Don't hand-write the `until … sleep` loop —
`pipeline-status.sh --job <name> [--watch]` wraps exactly this, resolving the
pipeline for the commit (or `--pipeline <id>` to pin it). The underlying calls:

```bash
# GitHub — jobs in a run, filtered by name (latest attempt if retried).
gh run view <run-id> --json jobs \
  | jq -c '[ .jobs[] | select(.name == "<job>") ] | sort_by(.databaseId) | last'

# GitLab — jobs in a pipeline, filtered by name.
glab api "projects/:fullpath/pipelines/<pipeline-id>/jobs?per_page=100" \
  | jq -c '[ .[] | select(.name == "<job>") ] | sort_by(.id) | last'
```

`glab ci status` / `glab ci get` and `gh run watch` exist for interactive use,
but the JSON-returning `gh run` / `glab api` forms above are what reason reliably
from a script.

## Binary upload (image attachments, GitLab)

`glab api` uploads a PNG straight through — no token, no `curl`, no web UI —
**as long as you reach for `--form`, not `-F`/`--field`.** They look
interchangeable and aren't: `-F` is short for `--field`, which JSON/string-
encodes an `@file` value — fine for a text file (a commit message, an MR
description) but it mangles binary content, which is the HTTP 400 this used to
produce. `--form` sends real `multipart/form-data`, which is what a binary
upload endpoint expects. Chasing the 400 into "glab can't do this, fall back to
`curl` with a raw token" is the wrong turn: it works, and the extra token
extraction it seems to demand is both unnecessary and a step downward — pulling
a token out of `glab`'s own credential store is exactly the kind of action a
permission classifier should (and will) balk at, and does not belong in a
script.

```bash
# 1. Get the numeric project id (the uploads endpoint requires it, not :fullpath).
glab repo view --output json | jq -r '.id'   # → 16529

# 2. POST the file — glab authenticates it the same as any other `glab api` call.
glab api --method POST "projects/<id>/uploads" --form "file=@/path/to/image.png"
# → { "markdown": "![image](/uploads/<hash>/image.png)", ... }
```

The returned `markdown` field embeds directly into an MR description — swap it
in before the write, and the description lands with working images on the
first PUT. No return trip through the web UI.

## Etiquette: history is mutable until the CR is marked ready

Gate history rewrites (amend, squash, rebase, force-push) on push state and
the CR's **draft flag** — declared author intent, which is reliable in a way
inferred engagement signals (note counts, reviewer lists) are not:

- **Unpushed commits** — yours; amend, squash, and rebase freely.
- **Pushed, CR still a draft** — mutable history is still the norm (`anchor`
  creates CRs as drafts for exactly this reason); amend and force-push with
  lease until it's marked ready.
- **Pushed, CR marked ready** — follow-up changes land as **new commits**.
  A new commit preserves the reviewer's "changes since you last looked"
  diff; force-pushing collapses that incremental view and marks inline
  threads outdated — and there is no reliable signal for whether someone
  has already looked.

Check the draft flag:

```bash
# GitLab
glab mr view --output json | jq '.draft'

# GitHub
gh pr view --json isDraft --jq '.isDraft'
```

Engagement signals (`glab api projects/:fullpath/merge_requests/<iid> | jq
'{reviewers, user_notes_count}'`, `gh pr view --json
reviews,reviewRequests,comments`) are advisory context for a prompt — they
never silently permit a force-push on a ready CR.

## Etiquette: fail fast on auth

On authentication or authorization failures — 401, 403, expired token, OAuth
refresh failure — stop after one attempt. Surface the error and ask the user to
refresh credentials. Don't retry the same call, don't try alternative endpoints
to work around it, and don't silently fall back to degraded behavior. Auth
failures are environmental (expired token, wrong account, network policy), not
transient; retrying burns the session without changing the underlying state.
Network failures (DNS, connection refused, timeout) follow the same rule: one
retry maximum, then stop and report.
