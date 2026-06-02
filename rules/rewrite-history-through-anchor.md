# Route history rewrites through anchor

When you're about to rewrite git history — `commit --amend`, a squash, a
rebase, any force-push — don't do it ad-hoc: use `/anchor:commit`, which
encodes when amending is safe and when the change must land as a new
commit, and recommends accordingly.

For rewrites the skill doesn't cover, gate on what's reliable at decision
time — push state and the CR's draft flag (`gh pr view --json isDraft` /
`glab mr view --output json | jq .draft`):

- **Unpushed commits** are yours — amend, squash, and rebase freely.
- **Pushed, CR still a draft** — mutable history is still the norm. Draft
  is the author's declared "not under review yet" (anchor creates CRs as
  drafts for exactly this reason); amend and force-push with lease freely
  until it's marked ready.
- **Pushed, CR marked ready** — follow-up commits. Reviewers rely on the
  "changes since you last looked" diff, and there is no reliable signal
  for whether someone has already looked — force-push only with the
  user's explicit sign-off. Squashing for clean history is the merge's
  job (squash-on-merge).
