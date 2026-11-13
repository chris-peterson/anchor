# Reading a diff

- Before anything anchor writes is published, you review it in
  [revdiff](https://revdiff.com), where you annotate and give the verdict.
- Two things in that review are anchor's, not yours: a `(context).md` file at
  the top of the tree, and notes already on some of the lines.
- The step most likely to surprise you is the last one: <kbd>q</kbd> no longer
  approves.

## What you need

revdiff 1.14 or later, from
[its install page](https://github.com/umputun/revdiff#installation).

On Windows, diff reviews run
[under WSL](https://github.com/umputun/revdiff/issues/66#issuecomment-6297017707):
install revdiff's Linux package there.

## 1. Start at `(context).md`

**Read the file at the top of the tree first.** Every revdiff review opens with
a `(context).md` at the top of the file tree: the change's title, the repo and
base commit, its size, and the Review box where you give the verdict. git never
sees the file, and it's removed when the review closes.

## 2. Read anchor's notes on the lines

**Treat the notes already in the diff as anchor explaining itself.** They are
anchor's, not a reviewer's: what it weighed, a constraint the code doesn't show,
or an area to pay close attention to. Edit one to correct it or comment, and the
edit goes back to the agent. Deleting one does nothing, so you can clear notes
as you step through. They're ephemeral: they expire along with the review
round, and none of their text goes into the code or the commit message.

**The first character of a note says whose it is and what it asks of you:**

| Opens with | It is | What you do |
| --- | --- | --- |
| 🤖 | anchor describing its own change, or answering one of your notes | read it; write on it only to question or correct it |
| 💡 | a suggestion: something anchor thinks you should do, such as keep a fix or post a comment | keep it, change it, or drop it |
| nothing | a note you wrote | nothing |

revdiff's own marker (💬 by default) is turned off for anchor's reviews, so the
emoji at the start of the note is the only one. Your own notes show no marker
unless you type one.

## 3. Leave your own notes

**Annotate only what you have something to say about.** When you send a commit
back with notes, the next review opens on only what changed since you last
looked, with an answer to each of your notes.

## 4. Give the verdict

> [!WARNING]
> Quitting with <kbd>q</kbd> and nothing of your own no longer approves. A box
> in the same pane asks Approve, Reject, or Go back, with focus on Go back.
> <kbd>Q</kbd> does nothing.

**End the review with a chord or a note.** With nothing to say,
<kbd>Z</kbd><kbd>Z</kbd> approves and <kbd>Z</kbd><kbd>Q</kbd> rejects, in
revdiff as in Helix or Vim. A single note saying `approve` or `reject` in
`(context).md` decides it too.

## In your editor instead

In an editor review, <kbd>Z</kbd><kbd>D</kbd> switches to revdiff, and exit 1,
Vim's `:cq`, rejects. Quitting with `:q!` makes the agent ask whether to accept,
reject, or reopen. revdiff can relaunch the review in your editor.

Editor reviews work in Git Bash with an editor that waits, such as Notepad or
`code --wait`.

## Several edits at once

Edits to several issues or milestones, or several review replies, open as one
review with an item per file. [Batch Editing](/guides/batch-editing) covers it.
