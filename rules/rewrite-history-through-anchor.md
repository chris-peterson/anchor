# Route history rewrites through anchor

When you're about to rewrite git history — `commit --amend`, a squash, a
rebase, any force-push — don't do it ad-hoc: use `/anchor:commit`, which
encodes when amending is safe and when the change must land as a new
commit, and recommends accordingly.

For rewrites the skill doesn't cover, gate on what's reliable at decision
time — push state and the CR's draft flag (`gh pr view --json isDraft` /
`glab mr view --output json | jq .draft`), **read fresh at the moment you
rewrite, never from an earlier turn** — it flips live. Prefer `/anchor:commit`,
whose pre-flight re-resolves it; raw `git commit --amend` /
`push --force-with-lease` has no such gate.

- **Unpushed commits you authored** — amend, squash, and rebase freely.
  First confirm HEAD's author is you (`git log -1 --format=%ae HEAD` vs
  `git config user.email`); amending rewrites HEAD in place, so a commit
  someone else authored is never a squash/amend target regardless of push
  state — land your work as a new commit.
- **Pushed, CR still a draft** — mutable history is still the norm. Draft
  is the author's declared "not under review yet" (anchor creates CRs as
  drafts for exactly this reason); amend and force-push with lease freely —
  but re-check it's *still* a draft at push time (per above); it stops being
  safe the instant it's marked ready.
- **Pushed, CR marked ready** — follow-up commits. Reviewers rely on the
  "changes since you last looked" diff, and there is no reliable signal
  for whether someone has already looked — force-push only with the
  user's explicit sign-off. Squashing for clean history is the merge's
  job (squash-on-merge).
