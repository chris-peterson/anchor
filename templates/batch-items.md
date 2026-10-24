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
`change_requests/`, `replies/`), and the table in `(context).md` groups its rows
under the same kinds.

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
