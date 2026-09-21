### Yes (write)

`anchor` assigns new issues to you, and applies the labels and milestone from Step 5 in the same write. The canonical invocations — including the `glab api`-then-`glab issue update` two-step GitLab needs for a file-sourced body, and the update-from-file forms — live in the bundled forge cookbook (`<anchor-root>/guides/forge-cookbook.md`), sections "Issue create", "Issue description update from a file", and "Labels and milestones".

When a target resolved (see **Target repo**), retarget these off the cwd repo: add `-R <TARGET_PROJECT>` to the `gh issue` calls; on GitLab substitute the URL-encoded `TARGET_PROJECT` for `:fullpath` and add `--hostname <TARGET_HOST>` on the `glab api` calls, and `-R <TARGET_URL>` on `glab issue update`.

Repeat `--label` per label; drop a metadata flag entirely where Step 5 settled on none.

```bash
# GitHub — create
gh issue create --title "<title>" --body-file <draft-path> --assignee @me \
  --label "<label>" --milestone "<milestone title>"

# GitHub — update (edit has no --label; --add-label adds without replacing)
gh issue edit <num> --body-file <draft-path> \
  --add-label "<label>" --milestone "<milestone title>"
```

```bash
# GitLab — create (API form so the body can come from a file), then the
# assignee and metadata in one porcelain follow-up
glab api -X POST projects/:fullpath/issues -F title="<title>" -F "description=@<draft-path>"
glab issue update <iid> --assignee <username> --label "<a,b>" --milestone "<milestone title>"

# GitLab — update
glab api -X PUT projects/:fullpath/issues/<iid> -F "description=@<draft-path>"
glab issue update <iid> --label "<a,b>" --milestone "<milestone title>"
```

After the issue lands, print its URL, and announce it so a sibling that resolves
its own work from tracker URLs can see the new issue without scraping one out of
your prose:

```bash
bash "<anchor-root>/scripts/announce.sh" issue.created \
  "uri=<issue url>" "title=<title>"
```

On a create only. Adding to an issue that already existed announces nothing: the
artifact a subscriber records already exists, and what this run changed is in your
report. The publisher exits 0 on every path, so this can never turn an issue that
landed into a tool call that failed.
