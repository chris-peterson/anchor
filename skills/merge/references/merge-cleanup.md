## Step 3: Merge

Run the merge for the chosen method (cookbook: "Merge a CR"). Delete the source
branch as part of the merge — `gh pr merge --delete-branch` / `glab mr merge
--remove-source-branch`. On GitHub this is the only place the branch gets cleaned
up unless the repo's `deleteBranchOnMerge` is on, since a PR carries no per-PR
preference; on GitLab it repeats what the create call set. This is a forge write:

- On a **401/403 or other auth failure**, surface it and ask the user to refresh
  credentials — do not retry or fall back (the fail-fast-on-auth rule).
- If the forge **rejects the merge** because a gate flipped since Step 1 (a new
  commit, a fresh unresolved thread, protection rules), re-read the specific gate it
  names and surface that — don't force past it.

### Announce the merge

Once the forge confirms it, read back what the forge recorded and announce it, so
a sibling tracking deliverables learns the CR landed and when:

```bash
# GitHub
gh pr view <num> --json url,title,mergedAt,mergeCommit \
  | jq -r '[.url, .title, .mergedAt, (.mergeCommit.oid // "")] | @tsv'

# GitLab
glab mr view <iid> --output json \
  | jq -r '[.web_url, .title, .merged_at,
            (.merge_commit_sha // .squash_commit_sha // .sha)] | @tsv'
```

```bash
bash "<anchor-root>/scripts/announce.sh" cr.merged \
  "uri=<url>" "title=<title>" "merged_at=<merged at>" "sha=<landed sha>"
```

Both halves are read back rather than assembled from what this run knows.
`merged_at` is the forge's own timestamp, so a subscriber records when the merge
happened instead of when it heard; and the landed commit sits under a different
field per method, which is why the queries above take the first one the forge
filled in.

The publisher exits 0 on every path, so this can never turn a merge that landed
into a tool call that failed. The contract it satisfies is in the marketplace repo
at [`authoring/plugin-contract.md`](https://github.com/chris-peterson/claude-marketplace/blob/main/authoring/plugin-contract.md).

## Step 4: Clean up

Once the forge confirms the merge, leave the local checkout on a clean footing:

1. **Return to the default branch and pull the merged result:**

   ```bash
   git -C <repo> checkout <target> && git -C <repo> pull --ff-only
   ```

2. **Delete the merged local branch.** The forge deleted the remote branch (Step 3);
   remove its local counterpart:

   ```bash
   git -C <repo> branch -d <head>
   ```

   `-d` refuses to delete a branch whose commits aren't merged — if it refuses,
   surface that rather than forcing with `-D`; it means the merged commit differs
   (e.g. a squash produced a new SHA). After a squash, the branch's commits are in
   the target under a new SHA, so `-d` will refuse; confirm the merge landed, then
   delete with `-D`.
