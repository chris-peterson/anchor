# Forge cookbook

Canonical `gh` (GitHub) and `glab` (GitLab) invocations for the operations
anchor's skills perform — creating and updating change requests (CRs: pull
requests on GitHub, merge requests on GitLab), filing issues, and posting
review comments. Both CLIs reason more reliably from explicit flags than from
guessing, so prefer these forms over re-deriving them.

Pick the CLI by the `origin` remote: a GitHub remote → `gh`; a GitLab remote →
`glab`. Both must be authenticated with read+write scope.

## Defaults anchor applies

When anchor creates a CR or an issue on your behalf, it applies these defaults.
They reflect a single-maintainer-friendly workflow; adjust per project as
needed.

| Default | GitHub | GitLab |
|---|---|---|
| **Create CRs as draft** | `gh pr create --draft` | `glab mr create --draft` |
| **Assign to yourself** | `--assignee @me` | `assignee_ids[]=<your-id>` (see below) |
| **Delete source branch after merge** | repo auto-delete setting, or `--delete-branch` at merge | `glab mr create --remove-source-branch` |
| **Assign issues to yourself** | `gh issue create --assignee @me` | `assignee_ids[]=<your-id>` |

GitLab has no `@me` shorthand. Capture your numeric user id once and reuse it
(`glab` has no `--jq` flag, so pipe to `jq`):

```bash
glab api user | jq -r '.id'
# → 122
```

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
# 1. Capture your user id and the current branch.
glab api user | jq -r '.id'          # → 122
git branch --show-current            # → my-feature-branch

# 2. Write the body to a unique temp path, then POST the MR.
glab api -X POST projects/:fullpath/merge_requests \
  -F title="MR title" \
  -F "description=@/tmp/cr-body.aB3xKp.md" \
  -F source_branch="my-feature-branch" \
  -F target_branch="main" \
  -F "assignee_ids[]=122" \
  -F remove_source_branch=true \
  -F draft=true
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

# GitLab (API form so the body can come from a file, assigned to you)
glab api -X POST projects/:fullpath/issues \
  -F title="Issue title" \
  -F "description=@/tmp/issue-body.aB3xKp.md" \
  -F "assignee_ids[]=122"
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

## Etiquette: don't amend after review starts

Once a CR has **review activity** — assigned reviewers, comments/discussions, or
approvals — make follow-up changes as **new commits**. Don't amend and
force-push over commits the reviewer has already seen: a new commit preserves
the "changes since you last looked" diff, and force-pushing collapses that
incremental view and marks inline threads outdated.

The constraint protects *pushed* commits a reviewer has seen. Amending is the
right default when no review has started, no reviewers are assigned, or the
commit you're amending is still unpushed. A pre-review rebase onto `main` (so the
branch can merge) is the blessed exception — do it before review begins.

Detect review activity with the matching forge tool:

```bash
# GitLab — reviewers / discussion count
glab api projects/:fullpath/merge_requests/<iid> | jq '{reviewers, user_notes_count}'

# GitHub — reviews / review requests / comments
gh pr view --json reviews,reviewRequests,comments
```

## Etiquette: fail fast on auth

On authentication or authorization failures — 401, 403, expired token, OAuth
refresh failure — stop after one attempt. Surface the error and ask the user to
refresh credentials. Don't retry the same call, don't try alternative endpoints
to work around it, and don't silently fall back to degraded behavior. Auth
failures are environmental (expired token, wrong account, network policy), not
transient; retrying burns the session without changing the underlying state.
Network failures (DNS, connection refused, timeout) follow the same rule: one
retry maximum, then stop and report.
