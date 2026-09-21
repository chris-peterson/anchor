## Step 6: Report

One line: the version, how it published, and where to see it —
`Released v1.2.0 (minor) — <release url>` for the models that publish a release
body, or `Released v1.2.0 (minor) in <sha>` for a bump commit. On
`dispatch-triggered` the version is the workflow's to derive, so report what the
run produced rather than what was recommended. Add the pipeline verdict
when Step 5 watched one.

### Announce it

Where a release exists on the forge, announce it, so a sibling tracking
deliverables learns what shipped:

```bash
bash "<anchor-root>/scripts/announce.sh" release.created \
  "uri=<release url>" "tag=<tag>"
```

Read both back from the forge rather than assembling them from the version this
run recommended. On `tag-triggered` and `dispatch-triggered` the workflow derives
the version and creates the release, so what it published is the only authority:

```bash
gh release view --json url,tagName                              # GitHub
glab release view -F json | jq '{url: ._links.self, tag_name}'  # GitLab
```

Both default to the project's latest release, which is what just published; name
the tag explicitly only where this run set it. GitLab's release object carries no
`url` of its own, so the web address is `_links.self` (cookbook: "Read back a
published release").

On `bump-commit` and `no-version-artifact` there is no forge release to name, so
announce nothing here; what landed is the bookkeeping commit, which
`anchor:commit` already announced as `commit.pushed`.

The publisher exits 0 on every path, so this can never turn a release that
published into a tool call that failed.
