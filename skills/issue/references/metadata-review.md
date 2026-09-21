## Step 5: Labels and milestone

An issue lands in someone's triage queue, so its metadata is part of filing it. Read what the project actually defines rather than naming a label from memory — an invented name is how a repo ends up with `bugfix` sitting next to `bug`. The listing calls for both forges are in the bundled forge cookbook (`<anchor-root>/guides/forge-cookbook.md`), section "Labels and milestones".

Both listings are pure-remote, so a resolved target needs no checkout — retarget per **Target repo**: `-R <TARGET_PROJECT>` on `gh label list` and `TARGET_PROJECT` substituted for `{owner}/{repo}` in the `gh api` path; `-R <TARGET_URL>` on `glab label list`, `--project <TARGET_PROJECT>` on `glab milestone list`, `--hostname <TARGET_HOST>` on both.

**Labels.** The descriptions the repo ships on its labels are the triage taxonomy — match the issue against them and apply every label that plainly fits. Two cases go to the user as structured choices when the host supports that, or as a direct question otherwise, rather than being decided for them: several labels are plausible and choosing between them is a judgment about the work (`bug` vs `enhancement` for behavior someone considers wrong), or nothing in the set fits an issue a reader would expect to be labelled. No label is a legitimate answer to either.

**Milestone.** Only the open ones (GitLab: `active`) are candidates. Attach one where exactly one plausibly fits — the release the work has to ship in, or the milestone whose theme this work is part of. Where two or more fit, ask; where the repo has no open milestone, or none relates to this work, attach none and don't raise it.

**On the update path, add only.** Read what the issue already carries (`gh issue view <num> --json labels,milestone` / `glab issue view <iid> --output json`) and treat it as settled: propose a label the issue is missing, and a milestone only where it has none. Replacing or removing what someone already triaged is something the user asks for.

## Step 6: Output

Write the drafted body to a temp file (`$(mktemp -u /tmp/issue-draft.XXXXXX).md`) — the literal `/tmp` is what a caller's path-scoped write grant reaches (`<anchor-root>/guides/temp-paths.md`).

**Present the change — in your own message.** Running a command is not a portable
way to show the user anything: hosts can hide or collapse tool output. Asking
them to approve off the back of that is asking them to approve blind. So
whatever you present goes in the reply as text.

When updating an existing issue, diff the draft against the baseline captured in Step 1 and **paste that diff** into a fenced `diff` block in your message:

```bash
git --no-pager diff --no-index <current-path> <draft-path>
```

When creating a new issue, display the full body in a fenced code block.

Either way, head the presentation with a line naming the write and linking where it lands, then the title, then the Step 5 metadata on one line. Emit them as markdown outside the fence, so the link is clickable. The first line takes the create form or the update form:

```markdown
New [`<project>` issue](<issue list url>)
Update [`<project>` #<number>](<issue url>)

Title: <drafted title>
Labels: <labels> · Milestone: <milestone title>
```

Say `none` on either half of the metadata line where Step 5 settled on none; it rides the one disposition question with the body rather than becoming a second gate.

Where the link points:

- **Create** — the target project's issue list: `TARGET_URL` where a target resolved, else the web URL of the cwd repo's `origin`, plus `/issues` on GitHub or `/-/issues` on GitLab.
- **Update** — the issue's own URL, which the forge reports as `url` (GitHub) / `web_url` (GitLab).

Then ask the user how to proceed, using structured choices when the host supports
that (header `Disposition`) or a direct question otherwise. Use these options
(default first):

- **Yes (write)** — create the issue (or push the updated body). The body comes from `<draft-path>`. On a 401/403 or similar auth failure, surface it and ask the user to refresh credentials — don't silently fall back to copy-only (per the fail-fast-on-auth rule).
- **No (copy only)** — print the title and body for the user to paste into the web UI themselves.
- **Edit** — adjust something, then re-present.
