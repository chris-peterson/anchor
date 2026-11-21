# What's new in 2.1

2.1 changes how `/anchor:review` moves through its rounds and how the notes in
a review read. Each round now shows only what it changed, a self-review ends in
one sign-off step, and a question you leave on a note gets an answer instead of
being treated as feedback.

Nothing needs configuring to get any of it. The few changes to how a review
ends are under [Ending a review](#ending-a-review), and what to know if you
customized 2.0 is under [Upgrading from 2.0](#upgrading-from-20).

## Review rounds

### Each round shows only what is new

In 2.0, every round after the first reopened the whole change from the review's
base, so most of what you read again was fixes you had already approved in an
earlier round's commit. Each round also opened three reviews where two did the
job.

| | 2.0 | 2.1 |
| --- | --- | --- |
| Reviews in a round | the items, the whole change, the round's commit | the items, the round's commit |
| What a later round's commit review shows | the whole change from the review's base | only that round's fixes |
| What a later round's agents examine | the whole change | only the lines the previous round changed |
| How a round ends | *Finish: whole change*, *Finish: just this round*, or *Another round* | *Is this the last round?* |

The whole change is still one pick away, once, in the
[final sign-off](#a-self-review-ends-in-a-sign-off).

### The first review of a commit runs the agents

The first time a given commit is put up for review, the quality agents start
while you read, without a question. anchor says so in one line, naming the
commit and how to stop them: say *no agents*. Reviewing the same commit again
asks first, as before, since the agents have already examined it. Saying
*I'll read it myself* or *just have the agents look* when you ask for the review
still decides it.

### Your progress between rounds

Before asking whether to go another round, the review draws a clipboard of
where it stands: each round done, how many fixes it kept and the lines it
changed, then the step ahead. The question that follows previews each round's
size on one scale, so you can see whether the rounds are shrinking:

```text
             ╭──────────╮
┌────────────┤ ▄▄▄▄▄▄▄▄ ├─────────────┐
│            ╰──────────╯             │
│                                     │
│   [x]  Round 1 · 3 fixes · +14 −3   │
│                                     │
│ > [ ]  Round 2                      │
│        …                            │
│   [ ]  Sign-off                     │
│                                     │
└─────────────────────────────────────┘
```

```diff
 round 1 · 2 files
+██▎ 14
-▌ 3
 original change · 6 files
+████████████████████ 120
-██████▋ 40
```

anchor recommends another round only when the round kept a fix to a real bug,
since that fix can carry a bug of its own. A round of polish is the next
round's diff, so otherwise it recommends finishing, and says so plainly when a
round changed no less than the one before it.

### A self-review ends in a sign-off

After the last round, the clipboard is drawn again with every round checked
off, and one question asks how the change leaves your hands. Pick any of these,
and they run in this order:

| Pick | What it does |
| --- | --- |
| **Look at the whole change** *(pre-picked)* | opens revdiff on the change as it will land, from the review's base. A note here starts one more round from your notes, with no agents |
| **Update the CR description** *(pre-picked)* | `/anchor:prepare-review` refreshes it for what the rounds changed |
| **Mark ready** | takes the CR out of draft |
| **Request reviewers** | asks who, then requests them |

Picking nothing leaves the CR a draft. On a branch with no CR yet, sign-off
offers **Look at the whole change** and **Open the CR** instead.

### On someone else's CR, the suggestions are code

Once you have read the change, the pass where you decide each item shows the
fixes the agent suggests, as code, and none of the CR itself. Each fix carries
a 💡 note saying why; answer `skip` on the note to drop it. In 2.0.1 that pass
showed the CR's own diff again, with each suggestion described in words on a
note, where a suggestion on a line the CR didn't touch was easy to miss.

## Notes in a review

These apply wherever anchor opens revdiff: `/anchor:commit`, `/anchor:issue`,
batch edits, and every pass of `/anchor:review`.
[Reading a diff](/guides/reading-a-diff) has the full key to anchor's notes.

### A question gets an answer, not a round trip

A note with a `?` in it is a question for the agent, whoever you wrote it to.
The agent checks the code or the facts before doing anything else, says so when
it can't be sure, and says what the answer changed: nothing, the reason on an
item, the fix itself, or dropping the item. The answers appear in chat, each
marked ❓, and again at the top of the next pass's `(context).md`.

A question never posts. In 2.0, *why not X?* on a draft for someone else's CR
was read as a finding of yours and was on its way to the author under your
name. Where only the author could know the answer, the agent offers to ask
them, as a comment you approve with the rest. A pass whose only notes were
questions goes on as approved once they're answered.

### Every reply can be found

- **Two replies in one place arrive as one note carrying both.** revdiff keeps
  one note per place, so in 2.0 the second reply replaced the first, most often
  on a note you left on a whole file.
- **A reply with no line in the diff is linked.** The table in `(context).md`
  used to say *end of file*; it now links to the reply's own heading
  (`Reply #N`).
- **Replies are a sentence.** The diff beside a reply shows how the change was
  made, so the reply says what was done and stops.

`/anchor:resolve-feedback` gets the same treatment: each thread in its triage
table links to the thread on the forge, since the one-line summary of what a
reviewer asked loses detail you may need to decide.

### The hints are one note away from gone

A note on the Review box's key list, such as *hide this*, turns those hints
off. The agent says so in a line, and the note doesn't count as feedback on
your change. Each kind of review keeps its hints under its own key, so hiding
them in one leaves the others showing
([`anchor.hints`](/guides/configuring?id=key-hints)).

## Ending a review

### A batch confirms when you quit

In a batch edit, and in the items pass of `/anchor:review`, answering an item
used to count as asking for the whole batch back, so quitting published nothing
unless you also knew to leave an `approve` note. Now <kbd>q</kbd> always opens
a Confirm box that counts what your answers decide (accept, edit, skip, new):

- <kbd>Z</kbd> or <kbd>Enter</kbd> confirms.
- <kbd>Q</kbd> stops, with nothing published.
- <kbd>Esc</kbd> goes back, with your answers kept.

[Batch Editing](/guides/batch-editing?id=ending-the-review) walks through it.

### A shorter Review box

The Review box in `(context).md` lists its keys in three groups: moving between
changes, leaving notes, and finishing with <kbd>q</kbd>,
<kbd>Z</kbd><kbd>Z</kbd>, or <kbd>Z</kbd><kbd>Q</kbd>. The instructions to leave
an `approve` note are gone, and so is the choice to relaunch the review in your
editor; <kbd>e</kbd> still edits a file in place.

The first pass of `/anchor:review`, where you read the change, now shows its
own guide. In 2.0 revdiff's generic header replaced it before the review
opened.

### Arrow keys work on a stock Mac

The verdict box runs under the first `bash` on your `PATH`, which on a Mac with
no newer bash installed is macOS's bash 3.2. There, every arrow key and click
read as <kbd>Esc</kbd>, so Right then Enter went back into the review instead
of rejecting. They now work as they do under a newer bash.

## Upgrading from 2.0

- **Hidden hints may reappear in two places.** If you set `anchor.diff.hints`
  to `false`, it now covers only revdiff reviews of a commit, CR description,
  issue, or release notes. The read pass of `/anchor:review` and batch reviews
  have their own keys, `anchor.review-read.hints` and `anchor.items.hints`.
  `anchor.hints false` still hides them everywhere.
- **The review record in a CR description changes shape on its own.** The
  `<!-- anchor:review-status … -->` comment now lists one commit per line,
  keyed by its sha, and taking off its first and last lines leaves plain JSON.
  A record written by 2.0 is read as before and moves to the new shape the next
  time anchor writes it.

Everything else in the release, including fixes outside reviews, is in the
[changelog](https://github.com/chris-peterson/anchor/blob/main/CHANGELOG.md).
