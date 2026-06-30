# Omit AI attribution trailers

Don't add AI or tooling attribution to anything you commit or open on a
forge. The default Claude Code harness appends a `Co-Authored-By: Claude …`
trailer to commits and ends PR/MR bodies with a
`🤖 Generated with [Claude Code]` line — anchor's artifacts carry neither.

- **Commit messages** — no `Co-Authored-By` trailer.
- **Change-request descriptions and issue bodies** — no
  `Generated with Claude Code` line, and no equivalent "made by an AI"
  footer.

Authorship is already recorded by the commit author and the CR/issue author
fields; restating it in the body is promotional noise the reader didn't ask
for. The only trailer anchor adds to a commit is the `Refs:` work-tracker
link, and only when you mention a ticket.
