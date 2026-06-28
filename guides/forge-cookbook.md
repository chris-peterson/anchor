# Forge cookbook

Canonical `gh` (GitHub) and `glab` (GitLab) invocations for the operations
anchor's skills perform — creating and updating change requests (CRs: pull
requests on GitHub, merge requests on GitLab), filing issues, and posting
review comments. Both CLIs reason more reliably from explicit flags than from
guessing, so prefer these forms over re-deriving them.

Pick the CLI by the `origin` remote: a GitHub remote → `gh`; a GitLab remote →
`glab`. Both must be authenticated with read+write scope.

When you run `glab` from **outside** a GitLab checkout — no `origin` to infer the
host from — target the host explicitly with `--hostname <host>`. That flag is
valid on **`glab api`** only; porcelain subcommands (`glab mr view`, `glab issue
view`, …) reject it with *"Unknown flag"*. So when you need to name the host,
reach for the `glab api` form of the operation rather than its porcelain
shorthand.

## Defaults anchor applies

When anchor creates a CR or an issue on your behalf, it applies these defaults.
They reflect a single-maintainer-friendly workflow; adjust per project as
needed.

| Default | GitHub | GitLab |
|---|---|---|
| **Create CRs as draft** | `gh pr create --draft` | `glab mr create --draft` |
| **Assign to yourself** | `--assignee @me` | `--assignee <username>` (see below) |
| **Delete source branch after merge** | repo auto-delete setting, or `--delete-branch` at merge | `glab mr create --remove-source-branch` |
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

Pick the path with `mktemp -u` (the `-u` prints a unique name *without* creating
the file, so a follow-up `Write` treats it as fresh). A random name also avoids
clobbering a parallel session that hardcodes the same path:

```bash
mktemp -u /tmp/cr-body.XXXXXX.md
# → /tmp/cr-body.aB3xKp.md
```

Run inner commands (like the `glab api user` id lookup) as their own step and
reuse the captured value — chaining with `$(…)` or `;`/`&&` trips structural
safety gates in some agents and prompts unnecessarily.

## GitLab-flavored markdown traps

Two facts about how GitLab renders an MR/issue body. Both produce output that
links the wrong target or renders wrong, and both are invisible in the markdown
source — they surface only once rendered.

**Cross-project references need the full URL.** The `#NNNN` (issue), `!NNNN`
(MR), and `@name` (user) shortcuts resolve *within the current project*. In an
MR, a bare `#1234` autolinks to issue 1234 of that MR's project — not to a
same-numbered item in another project. CI/deploy pipelines routinely live in a
different project than the MR, so any reference to a pipeline, issue, or CR
outside the current project must use the full URL. The bare shortcut silently
links the wrong thing.

**Tables can't be indented under a list item.** A table indented beneath a list
item renders unreliably in GitLab-flavored markdown. Keep tables at root level —
break them out of the surrounding list rather than nesting them under a bullet.

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

GitHub branch deletion on merge is a repo setting; if it's off, pass
`--delete-branch` to `gh pr merge` at merge time.

## MR create (GitLab)

`glab mr create -d` only accepts a `<string>` (or opens an interactive editor —
undriveable from an agent), so use the API form for a file-sourced body:

```bash
# 1. Capture your username and the current branch.
glab api user | jq -r '.username'    # → chris
git branch --show-current            # → my-feature-branch

# 2. Write the body to a unique temp path, then POST the MR.
#    (No assignee here — glab api can't encode array fields; see the note
#    under "Defaults anchor applies".)
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

## MR / PR description update from a file

Editing the body of an existing CR.

```bash
# GitHub
gh pr edit <num> --body-file /tmp/cr-body.aB3xKp.md

# GitLab — `glab mr update -d` doesn't accept a file; use the API form.
glab api -X PUT projects/:fullpath/merge_requests/<iid> \
  -F "description=@/tmp/cr-body.aB3xKp.md"
```

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

## Issue / MR comment from a file

`glab issue note` / `glab mr note` only accept `-m <string>` or open an editor.
Use the API form for a file-sourced comment:

```bash
glab api -X POST "projects/:fullpath/merge_requests/<iid>/notes" \
  -F "body=@/tmp/comment.aB3xKp.md"
```

`gh` accepts a file directly: `gh pr comment <num> --body-file <path>`.

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
**workflow run** (the *Actions* tab), GitLab a **pipeline**. anchor uses
**pipeline** as the generic term for both — pick `gh run` on a GitHub origin,
`glab` (the pipelines API) on a GitLab one. The `/anchor:pipeline` skill and its
`scripts/pipeline-status.sh` helper wrap the invocations below; reach for them
directly when scripting a one-off.

**Find the pipeline for a commit.** Resolve by branch, then pin to the exact
commit SHA — the latest run on a branch isn't always the one you pushed.

```bash
# GitHub — list recent runs and pick the one whose headSha matches.
gh run list --branch <branch> --limit 25 \
  --json databaseId,status,conclusion,headSha,url \
  | jq -c --arg sha "<sha>" '[ .[] | select(.headSha == $sha) ] | .[0]'

# GitLab — the pipelines API filters by ref + sha directly.
glab api "projects/:fullpath/pipelines?ref=<branch>&sha=<sha>&per_page=1" \
  | jq '.[0]'   # → {id, status, web_url, sha, ...}
```

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

`glab api ... -F "file=@image.png"` returns HTTP 400 for binary multipart
uploads. Fall back to authenticated `curl`:

```bash
# 1. Get the numeric project id (the uploads endpoint requires it, not :fullpath).
glab repo view --output json | jq -r '.id'   # → 16529

# 2. POST the file with the token glab already uses.
curl -sS -X POST "<gitlab-host>/api/v4/projects/<id>/uploads" \
  -H "PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN" \
  -F "file=@/path/to/image.png"
# → { "markdown": "![image](/uploads/<hash>/image.png)", ... }
```

The returned `markdown` field embeds directly into an MR description.

## Etiquette: history is mutable until the CR is marked ready

Gate history rewrites (amend, squash, rebase, force-push) on push state and
the CR's **draft flag** — declared author intent, which is reliable in a way
inferred engagement signals (note counts, reviewer lists) are not:

- **Unpushed commits** — yours; amend, squash, and rebase freely.
- **Pushed, CR still a draft** — mutable history is still the norm (anchor
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
