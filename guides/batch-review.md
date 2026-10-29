# Reviewing a batch of edits

When a skill has drafted the same kind of edit for several targets (bodies for
several issues, replies on several threads), the user approves the set in
revdiff rather than in chat. Each item becomes a file showing its current text
against the proposed one, `(context).md` lists them, and notes in the diff
carry what the reviewer needs to judge each edit. A reply holding several drafts
is terminal scrollback: the first drafts scroll away before the question
arrives, and the approval ends up covering text nobody read.

Use it for two or more items. A single item keeps its skill's own review, since
one file needs no table.

The mechanics are in `scripts/batch-edit.sh`, on the table, notes, and read-back
it shares with a review round (`scripts/lib/item-review.sh`); this guide is how a
skill drives it. What each kind of item's file holds, and how a kept one
publishes, is in `templates/batch-items.md`.

## Lay out the batch

Write each item's current text and proposed text to temp files
(`$(mktemp -u /tmp/batch-item.XXXXXX).md`), then an items file in the shape the
script documents at its top, and start the batch:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/batch-edit.sh" start --items <items.json> --title '<what the batch does>'
```

- **`file`** is the item's path in the batch tree, in the directory for its
  kind (`milestones/`, `issues/`, `change_requests/`, `replies/`) and named as
  `templates/batch-items.md` gives it. The table groups its rows by that
  directory, and the script refuses an item outside them. In a batch whose
  items span repos, the repo's name sits below the kind
  (`issues/<repo>/<number>.md`), and the `id` names it too (`<repo>#<number>`),
  since two repos can both have an issue with the same number. The script reads
  each item's repo from its `url` and refuses a path that leaves it out.
- **`current`** is omitted for an item that doesn't exist yet. It shows as a
  new file.
- **`summary`** is the item's row in the table: what the edit does, in a few
  words.
- **`url`** is where the item lives on the web (the issue, the thread), so the
  reviewer can open it rendered. The table links it.
- **`notes`** are optional, and most items need none. Add one only when judging
  the edit would otherwise mean looking something up: the reviewer comment a
  reply answers, the thread that settled a change, a choice the reviewer is
  likely to reverse. A note that restates the diff or the summary, or confirms
  what didn't change, is noise. Anything a future reader of the artifact needs
  goes in the text instead. Give a note the `line` of the proposed text it is
  about, so it sits beside that text; leave `line` out for a note about the
  issue, CR, or thread the item stands for, which sits on the file
  (`running-a-review.md`, "Put each note where the reader is already looking").

Every item also opens with a note the script writes, naming it by id and title
with its link under it: `#<n>` for a numeric id, the way the forge shows an
issue or thread, and the id as it is otherwise. A compact diff hides unchanged
lines, title included, so this note is what identifies the file.
A file-level note from `notes` is folded in below it.

Fields that travel with a body go in a header block at the top of the item's
text, so one diff shows every change to the item; the convention is in
`templates/batch-items.md`.

`BATCH_ERROR` lines name an item the batch refused (a proposal identical to the
current text, a note past the end of its file); fix them and start again. Keep
`BATCH_DIR`, `BATCH_ROOT`, `BATCH_BASE`, and `NOTES`.

## Open it in revdiff

Run it the way `running-a-review.md` describes, with the probe, the background
launch, and chat feedback held while it's open:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-diff.sh" --skill <skill> --tool revdiff --mode diff \
  --repo <BATCH_ROOT> <BATCH_BASE> --untracked --annotations <NOTES> \
  --title '<what the batch does>' --detail <label>=<value>
```

`--untracked` puts the new items in the file tree, and `(context).md` is shown either way.

**The manifest** names the targets (the repo, the CR), lists each item with a
link to it on the web, and says how to answer. Put the answer key in the reply, so nobody has to open the table to
learn it:

> Each item is a file: current text on the left, proposed on the right. Edit a
> file to change it yourself, or leave a note on it to have it redrafted. Answer
> `drop` on an item's note (or `no`, `skip`) to drop it. When you're done, leave a
> single note in `(context).md`, off the rows, saying `approve` to send the items
> as you left them or `reject` to stop with nothing published, then quit with `q`.

`rejected` publishes nothing: finish the batch and say so, with no error banner.
`no-verdict` with `raw.exitCode` `undecided` means the reviewer quit without
choosing: ask, with `AskUserQuestion`, whether to send the items as they left
them, stop, or reopen the review, and read the answer as `approved`, `rejected`,
or another launch.

Where the probe says revdiff can't open (`REVIEW_AVAILABLE=0`), or the review
comes back any other `no-verdict` or with no `REVIEW_RETURNED` line, nothing publishes:
open and close the reply with the error banner from `review-fallback.md`, name
what happened, and ask whether to retry or stop. A chat table of the drafts is
not a fallback for a batch.

## Read the answer

`approved` and `changes-requested` both mean the review ran: with notes
preloaded, revdiff returns whatever notes are left, and the notes are the
answer. `approved` publishes as the decisions below say; `changes-requested`
publishes nothing yet, and every item not dropped goes into the next batch, the
ones marked `change` redrafted.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/batch-edit.sh" read --dir <BATCH_DIR> --returned <REVIEW_RETURNED>
```

`BATCH_READ` holds one entry per item, with its `decision`:

| Decision | What the reviewer did | Act |
| --- | --- | --- |
| `keep` | left the item as it was, or answered a note with a yes (`ok`, `lgtm`, 👍) | publish the proposed text |
| `edited` | edited the item's file | publish their text verbatim, without redrafting or re-presenting it |
| `change` | left any other note on the file or its row, edited the row, or broke the header | redraft from `notes` and `rowNotes` (or `fieldsError`); it goes into the next round |
| `drop` | answered a note with `drop`, `no`, or `skip`, or deleted the row | nothing publishes for it |

Each entry carries `body`, a file holding the final text below any header, and
`fields`, the header parsed into an object. Publish from those. A seeded note
the reviewer deleted is tidying and changes nothing. `general` holds notes left
off the rows, or outside the items: they apply to the whole batch, so act on
them before publishing anything. A note that asks to hold the batch holds all of
it.

## Publish, then go again for what changed

On `approved`, publish the `keep` and `edited` items, then finish the batch:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/batch-edit.sh" finish --dir <BATCH_DIR>
```

When any item came back `change`, redraft those and start a new batch of just
them, with the redrafted text as the proposal. Approval of one round is not
approval of the next. Finish a batch on every stop too, so no scratch tree
outlives the review.

Report one line per item: its target, linked to where it landed, and
published, dropped, or still open.
