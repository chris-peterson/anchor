# Backups

Before `anchor` overwrites anything on the forge, it saves what was there: a CR's
description, an issue, a milestone. Forges keep edit history unevenly, and a
write can land on the wrong item, so the copy lives in your checkout, where it
doesn't depend on the forge. Nothing is written when the save fails, or when the
item it saved isn't the one you approved.

This page covers where those copies are kept, and how to put one back.

## Where they're kept

```text
<repo>/.git/anchor/backups/<kind>-<number>-<UTC time>-<pid>.<json|md>
```

The directory is inside git's own directory, so git never tracks it and it
survives the session that wrote it. Every worktree of a repo shares one set:
from a worktree, `git rev-parse --git-common-dir` gives the `.git` it lives
under.

| File | Saved before | Holds |
|---|---|---|
| `cr-<n>-….md` | `/anchor:prepare-review` writes a description | The description alone, exactly as the CR held it |
| `cr-<n>-….json` | `/anchor:ready`, a review round recording the Review status, a label or milestone edit | The whole CR: title, body, labels, milestone, state, draft flag, URL |
| `issue-<n>-….json` | `/anchor:issue` updates one issue or publishes a batch | The whole issue: title, body, labels, milestone, state, URL |
| `milestone-<n>-….json` | A batch that changes a milestone | The milestone as the forge's API returns it |

An item from a project other than `origin`'s gets the project's path in front of
its name, such as `acme-widget-issue-<n>-….json`. The time is UTC, so sorting by
name or modification time gives the same order, and **the newest file for an
item is that item as it stood just before `anchor` last wrote to it.**

GitHub's JSON keeps the body under `body` and labels as objects (`.labels[].name`).
GitLab's keeps it under `description` and labels as plain strings.

Nothing deletes these files. They're small, and only an undo reads them, so
clearing out old ones is safe whenever you want.

## Restoration

**Ask the agent to put it back**, naming the item and, when it isn't the newest,
which backup: *"restore the CR's description from before your last write"*. No
skill owns a restore, so the agent works from the file. A restore publishes
under your name like any other write, so ask to see the text before it goes out.

Restoring is itself an overwrite. **Have the agent save what's there now first**
(`anchor`'s `scripts/forge-backup.sh --kind <cr|issue|milestone> --id <n>`), so
the restore can be undone too.

> [!TIP]
> **Restoring a CR description rolls back its review record.** A CR's description ends with a **Review status** comment the forge doesn't render: each commit, how many times it's been reviewed, by whom, and the findings you dropped. A backup holds that record as it stood when it was saved, so an older description brings back an older record: `/anchor:review` and `/anchor:merge` see the commits reviewed since as unreviewed, and a finding you dropped since can come up again. To keep the record, restore the prose and leave the `<!-- anchor:review-status` block that's on the CR now in place.

### Manually

These run in any bash, including Git Bash on Windows. `jq` is the one `anchor`
already needs.

```bash
cd "$(git rev-parse --git-common-dir)/anchor/backups"
ls -t cr-<n>-*                     # newest first
```

A **CR description** saved as `.md` goes back as it is:

```bash
# GitHub
gh pr edit <n> --body-file cr-<n>-<time>-<pid>.md

# GitLab: `glab mr update` takes no file, so use the API
glab api -X PUT projects/:fullpath/merge_requests/<n> \
  -F "description=@cr-<n>-<time>-<pid>.md"
```

A **CR or issue** saved as `.json`: pull the body out into its own file, then
write it the same way.

```bash
body=$(mktemp)
jq -r '.body // .description' <kind>-<n>-<time>-<pid>.json > "$body"

gh issue edit <n> --body-file "$body"                                # GitHub; a CR: gh pr edit
glab api -X PUT projects/:fullpath/issues/<n> -F "description=@$body" # GitLab; a CR: merge_requests/<n>
```

The other fields come back the same way, one edit each. See what the backup held
next to what the item holds now:

```bash
jq '{title, state, milestone: (.milestone.title // null), labels: [.labels[] | (.name? // .)]}' \
  <kind>-<n>-<time>-<pid>.json
gh issue view <n> --json title,state,milestone,labels                         # GitHub
glab issue view <n> --output json | jq '{title, state, milestone: .milestone.title, labels}'   # GitLab
```

Then set what differs with `gh issue edit` / `gh pr edit` (`--title`,
`--add-label`, `--remove-label`, `--milestone`), `gh issue reopen`, or `glab api
-X PUT` with the fields that changed. The [forge cookbook](/guides/forge-cookbook)
has the GitLab forms.

