# Reading a reviewer's edits

Some review tools take feedback as annotations. A difftool takes it as *edits*:
the reviewer opens the changeset, writes into it, and quits. anchor snapshots
every reviewed file before the tool opens and reports each one they changed,
carrying the diff of what they wrote (`comments[].target: "file"`, with the
patch in `body` and `raw`).

That diff is not a list of instructions. It is a mix of two different things,
and separating them is your job — the script can say *what changed*, but only
you can say which kind of change it was.

## The two kinds

**A fix.** The reviewer typed the correction straight into the code. It is
already in the working tree, so there is nothing to apply — read it, make sure
you understand *why* it was right, and check whether the same mistake is
anywhere else in the changeset. If the fix contradicts something the change was
deliberately doing, say so rather than accepting it silently.

**A question or a note.** The reviewer left it in whatever comment syntax the
file already uses — `// why is this ordered?`, `# TODO: handle nil`,
`<!-- is this still true? -->`. These are addressed to you, and they must not
reach the commit:

1. **Answer it** in your reply, or make the change it asks for.
2. **Remove the line** from the file. A question the reviewer typed is a
   comment on the change, not part of it, and one left behind ships to `main`.
3. Where the answer is worth keeping in the code, write it as a real comment in
   your own words — not the question with a reply bolted on.

Deciding which kind you are looking at is the whole task, and the file tells
you: a line that reads as prose addressed to a person is a note, and a line that
reads as code doing the thing is a fix. When a single edit is genuinely both —
a fix plus a note about it — treat the halves separately.

## Before you re-review

**Every comment line the reviewer added is out of the tree.** Grep the files
they touched for what they wrote; a question that survives into the commit is
the failure this step exists to prevent, and it is invisible in a diff you have
already read once.

Then re-run the review. The reviewer sees the result of their own edit — their
fix kept, their question answered and gone — which is what makes the round trip
worth taking rather than a second copy of the first one.

## What not to do

- **Don't treat the edit as approval.** The tree changed, so the changeset the
  reviewer graded is not the one that would land. That is why edits come back as
  `changes-requested` rather than `approved` with a note.
- **Don't expand past what they touched.** Their edit scopes the work; the rest
  of the file is out of scope ([changeset-scope](changeset-scope.md)).
- **Don't re-litigate a fix by reverting it.** If you think it is wrong, keep it
  and say why you disagree, or ask. Quietly undoing a reviewer's own edit and
  re-presenting the result is the one move that makes the next review worthless.
