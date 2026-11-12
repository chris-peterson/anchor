# Batch Editing

Some requests touch many things on the forge at once: relabel a set of issues,
close the ones a release finished, plan a release's milestones and file the
issues under them, answer every open thread on a CR. Each of those is text
published under your name, so each one needs your approval.

Before 2.0, that meant one approval per item, or one prompt in chat asking for an
answer to each. Either way the drafts arrived as scrollback: the first ones had
scrolled away by the time the question came, and an approval ended up covering
text nobody had read.

Now the whole set opens as one review in [revdiff](https://revdiff.com). You read
every item, decide each one where it sits, and nothing publishes until you
approve the set.

## Skills with Batch Support

Two skills draft forge edits in bulk, and either one opens a batch once it has
two or more edits for you to approve. With only one, you get that skill's usual
review instead.

| Skill | What the batch holds |
| --- | --- |
| `/anchor:issue` | Edits to several issues: bodies, titles, labels, milestone, open or closed. Also new issues, the milestones a release plan creates or moves, and an open CR moved along with its issues. |
| `/anchor:resolve-feedback` | The replies drafted for a round of review threads. |

## What you see

Each item is its own file, showing the text the forge holds now against the text
proposed for it. A new issue or a reply has no current text, so it shows as a new
file.

An issue, CR, or milestone keeps its fields in a header above its body, so one
diff shows every change to it:

```text
title: <title>
labels: <label>, <label>
milestone: <milestone title, or none>
state: <open | closed>
---

<body>
```

A note at the top of each file names the item and links to it on the forge, so
you can open it rendered. Where judging an edit would otherwise mean looking
something up, such as the reviewer comment a reply answers, a note beside the
text carries it.

`(context).md`, at the top of the file tree, lists every item in a table grouped
by kind (milestones, issues, change requests, replies), with a link and a
one-line summary of what each edit does. It also holds the Review box where you
give the verdict for the whole batch.

## Answering each item

| To | Do this | What happens |
| --- | --- | --- |
| Send it as drafted | Leave it alone, or answer its note with `ok`, `lgtm`, or 👍 | It publishes as proposed |
| Send your own text | Edit the item's file | Your text publishes as you saved it, without being redrafted |
| Have it redrafted | Leave any other note on the file or its row | It's redrafted and comes back in the next round |
| Drop it | Answer its note with `drop`, `no`, or `skip`, or delete its row in `(context).md` | Nothing publishes for it |

A note in `(context).md` that isn't on a row applies to the whole batch, and is
acted on before anything publishes.

## Ending the review

Note only what you have something to say about. An item you leave alone is sent
as drafted, so a batch you agree with needs no notes at all.

- **Nothing to say:** <kbd>Z</kbd><kbd>Z</kbd> sends every item and
  <kbd>Z</kbd><kbd>Q</kbd> stops with nothing published. <kbd>q</kbd> asks the
  same thing in the pane: Approve, Reject, or Go back.
- **Some items need work:** leave your notes and quit. Nothing publishes yet;
  the noted items are redrafted and the batch comes back for another look.
- **Send the rest now:** add a note saying `approve` in `(context).md`, off the
  rows, before you quit. The items you left alone publish, and only the noted
  ones come back. `reject` there stops the whole batch.

A word like `approve` on an item's own note answers that item, not the batch,
which is why the batch-wide one goes in `(context).md`.

## After you approve

The kept and edited items publish. Before each edit to an existing issue, CR, or
milestone, the item is saved to `.git/anchor/backups/`, so it can be
[put back](/guides/backups). Milestones publish before issues, so an issue can
name a milestone the same batch creates.

Items you asked to have redrafted come back as a new, smaller batch holding only
them. Approving one round doesn't approve the next, so you see the redrafted text
before it goes out.

The agent ends with one line per item: where it landed, and whether it was
published, dropped, or is still open.

> **Same table, different subject.** An `/anchor:review` round uses the same
> table and answers, but its items are fixes in your code rather than edits on
> the forge. See [`review`](/skills/review).
