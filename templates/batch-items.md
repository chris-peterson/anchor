# Batch item templates

The shape of each kind of item a batch review carries: the file it is laid out
as, the fields its header holds, where its current text comes from, and what a
kept item writes. `guides/batch-review.md` owns the *technique*: laying out the
batch, opening it, reading the answer. This file owns the *shapes*, so a batch
mixing kinds (a release plan's milestones and the issues filed under them) reads
the same way item to item.

Every item file follows one convention. Fields that travel with the text go in a
header block, `key: value` lines ended by a `---` line, and the text itself is
the body below it. The current text is written in the same shape as the proposed
one, so an unchanged field doesn't show as an edit. A kind with nothing but a
body has no header.

Each kind has its own directory in the batch tree (`milestones/`, `issues/`,
`change_requests/`, `replies/`, `comments/`), and the table in `(context).md` groups its rows
under the same kinds. In a batch whose items span repos, every file name below
starts with the repo's name as a directory above its kind (`<repo>/issues/<number>.md`),
and each `id` names it (`<repo>#<number>`).

A round of `/anchor:review` runs on the same table, notes, and read-back
(`scripts/lib/item-review.sh`), but its items are fixes in the code tree rather
than files in a batch; their shape is the items file `scripts/review-round.sh`
documents.

## Issue

Used by the `issue` skill's "Several issues at once".

- **File**: `issues/<number>.md` for an update, `issues/new-<slug>.md` for a new
  issue.
- **Header and body**:

  ```text
  title: <title>
  labels: <label>, <label>
  milestone: <milestone title, or none>
  state: <open | closed>
  ---

  <body>
  ```

- **Current text**: `gh issue view <num> --json title,labels,milestone,state,body`
  / `glab issue view <iid> --output json`.
- **`url`**: the issue's web URL; a new issue has none yet.
- **Publish**: the `issue` skill's Step 6 write calls, applying the difference
  from the current fields: a changed title, the labels added and removed, the
  milestone, and the state (`gh issue close` / `reopen`, `glab issue close` /
  `reopen`). A milestone that is already closed takes the API form in the forge
  cookbook's "Labels and milestones" on GitHub, where `--milestone` finds open
  ones only.

## Change request

Used by the `issue` skill when a batch moves an open CR along with its issues,
such as onto the next release's milestone.

- **File**: `change_requests/<number>.md`, one directory for PRs and MRs alike.
- **Header and body**: the Issue item's, with the CR's description as the body.
- **Current text**: `gh pr view <num> --json title,labels,milestone,state,body`
  / `glab mr view <iid> --output json`.
- **`url`**: the CR's web URL.
- **Publish**: `gh pr edit` / `glab mr update` for the fields that changed. A
  changed body goes through `/anchor:prepare-review` instead, since a CR
  description has its own shape.

## Milestone

Used by the `issue` skill when a batch plans a release: creating the milestones
it ships into and moving the ones already open.

- **File and id**: `milestones/<title>.md`, with the title as the item's `id`,
  since both forges show a milestone by its title. A new milestone is a new file
  under the title it will have. Keep the GitHub `number` or GitLab `id` the edit
  calls take outside the batch.
- **Header and body**:

  ```text
  title: <title>
  due: <YYYY-MM-DD, or none>
  state: <open | closed>
  ---

  <description>
  ```

- **Current text**: `gh api repos/{owner}/{repo}/milestones/<number>` (`title`,
  the date part of `due_on`, `state`, `description`) / `glab api
  projects/:fullpath/milestones/<id>` (`title`, `due_date`, `state` with `active`
  as `open`, `description`).
- **`url`**: the milestone's `html_url` / `web_url`; a new one has none yet.
- **Publish**: before any issue item, since an issue can name a milestone the same
  batch creates. A new item is a create; an existing one is an edit sending only
  the fields that changed. The calls, the due-date encoding, and closing are in
  the forge cookbook's "Milestone create and edit". Read the stored due date back
  from the response, and report one that differs from the approved date.

## Thread reply

Used by `resolve-feedback` when two or more replies are drafted in a round.

- **File**: `replies/<n>-<basename>-<line>.md`, holding the reply exactly as it
  will post. No header.
- **Current text**: none; a reply is new.
- **`url`**: the thread's web URL.
- **Notes**: a file-level note quoting the reviewer's comment, so the reply is
  read beside what it answers.
- **Publish**: the item's `body`, posted on its thread.

## Review comment

Used by `review` on someone else's CR, for every batch of comments it would
post, however few: the comments go out under the user's name, so each one's
exact text is approved in the batch, never in a chat dump followed by a
post-all-or-one-at-a-time question.

A comment clears the bar only when it asks for a change or for clarification,
and sits on a line of the CR's diff. Praise, agreement, *lgtm*, a summary of
the review, and anything with no line to sit on are not comments and never
reach the batch.

- **File**: `comments/<n>-<basename>-<line>.md`, `<n>` its number in the
  findings, holding the comment exactly as it will post: the reason, and for a
  suggestion a blank line and the forge's suggestion block. No header.
- **Current text**: none; a comment is new.
- **`id`**: `<n>`, the finding's number.
- **`url`**: the CR's web URL.
- **Notes**: a file-level note naming where it posts, `<file>:<line>` and the
  side, with the line's text, so the comment is read beside the code it sits on.
- **Publish**: the item's `body` as the finding's `body` in the findings file,
  posted by `review-post.sh`.

## Overall comment

Used by `review` beside its review comments, as the one place the user writes
an overall comment if they want one. The agent never drafts it: an overall read,
a summary, or a verdict is the reviewer's to give.

- **File**: `comments/overall.md`, a new file holding one line, the placeholder
  `<!-- Write an overall comment below to post one; leave this file as it is to post none. -->`.
- **`id`**: `overall`.
- **`url`**: the CR's web URL.
- **Publish**: the item's `body` with the placeholder line taken out, as the
  findings file's `summary`. Left as it is, or empty once the placeholder is out,
  nothing posts.
