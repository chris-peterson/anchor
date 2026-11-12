# Notes on your own changes

An explanation lasts as long as it stays true
([the tenet](/?id=tenet-transient), UX-12): a comment for why the code is this
way, the commit message or CR description for why the change exists, and a note
on the line for why this line is this way, what you weighed, and what you want
checked. That last kind is what a reviewer needs right now and nobody needs
later. Without a home of its own it leaks into the permanent text: a commit
message that narrates every hunk, a description that walks the diff, a comment
that explains a decision to whoever reads the file next year. A note carries it
to the one reader it is for, so the permanent text can stay short.

## When a note earns its place

- **Where a reader would stop and ask why.** A choice among alternatives, a
  constraint the code can't show, an edge case the change handles, a spot you
  aren't sure of and want looked at.
- **It says what the diff can't.** Reading the note and reading the line should
  leave the reader knowing more than the line alone.
- **One per hunk at most**, one to three sentences. A mechanical change (a
  rename, formatting, moved code, a generated file, a lockfile) gets none.
- **A changeset with nothing to ask about gets no notes.** The count follows the
  questions a reader would have, not the size of the diff.

## Where it goes

On the changed line it explains, usually the first line of its hunk. A note
about a file as a whole goes on the file.
`review-diff.sh --notes` anchors each note where revdiff draws it and refuses
one on a file outside the review or a line far from every change: a note
explains a change, so it sits on one. A note on a file the review leaves out,
because nothing in it changed, goes in `(context).md` with the lines it is
about, since showing it in the diff would open the whole file.

A note isn't a draft of anything permanent. When its reason stays true as long
as the code does, it is a comment, and the comment is written into the change.
When it says why the change exists, it belongs in the message.

## How the reviewer answers

| They | It reads as |
| --- | --- |
| leave the note | read |
| delete the note | read and set aside |
| write on it | feedback, like any comment: a question to answer, or a change to make |

A reviewer who wants a note's reason kept says so on the note, and that is
feedback like any other: fold it into the message or a comment, and the text
comes back for review.

An editor review can't show preloaded notes, so it opens without them; the
probe's `REVIEW_PRELOADS=0` says so before the launch, and the notes go in the
manifest instead, one line each with its `file:line`.
