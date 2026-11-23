# What's new in 2.1

2.1 reworks `/anchor:review`:

- Each round shows only what that round changed.
- A self-review ends in one sign-off step.
- A question you leave on a note gets an answer.

You don't need to configure anything. If you customized 2.0, read
[Upgrading from 2.0](#upgrading-from-20).

## Review rounds

### Each round shows only what is new

In 2.0, every round after the first reopened the whole change, so you read
fixes you had already approved again. In 2.1 a round shows only its own fixes,
and the agents examine only those lines.

```text
 Round 2 in 2.0                        Round 2 in 2.1
 ────────────────────────────────      ────────────────────────────────
 1. the items                          1. the items
 2. the whole change                   2. this round's commit
 3. this round's commit
                                       this round's fixes only
 whole change from base                1 file   +6 −2
 6 files  +140 −45
```

The round ends with one question: *Is this the last round?* You can still look
at the whole change once, at [sign-off](#a-self-review-ends-in-a-sign-off).

### Agents start on the first review of a commit

The first time a commit is reviewed, the quality agents start while you read,
with no question asked first. anchor says so in one line. Say *no agents* to
stop them. When you review the same commit again, anchor asks first.

### Your progress between rounds

Before asking about another round, anchor shows where you stand, then each
round's size on one scale:

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

anchor recommends another round only when the last one fixed a real bug, since
that fix can carry a bug of its own. Otherwise it recommends finishing.

### A self-review ends in a sign-off

After the last round, one question asks how the change leaves your hands. The
picks you choose run in order:

```text
How should this change leave your hands?

  [x] Look at the whole change     revdiff from the review's base
  [x] Update the CR description    /anchor:prepare-review
  [ ] Mark ready                   takes the CR out of draft
  [ ] Request reviewers            asks who, then requests them
```

A note on the whole change starts one more round, with no agents. If you pick
nothing, the CR stays a draft. A branch with no CR is offered **Open the CR**
in place of the last three picks.

### Suggestions to another author are code

The pass where you decide each item now shows the suggested fix itself, not the
CR's diff with the fix described on a note. A fix to a line the CR didn't touch
was easy to miss that way.

```diff
 2.0.1 · the CR's diff, the fix described in words
   name := user.Name
                       💡 Suggest guarding against a nil user here

 2.1 · the fix, as code
+  if user == nil {
+      return ""
+  }
   name := user.Name
                       💡 user is nil once the session expires
```

Answer `skip` on a 💡 note to drop that fix.

## Notes in a review

These changes apply wherever anchor opens revdiff: `/anchor:commit`,
`/anchor:issue`, batch edits, and every pass of `/anchor:review`.
[Reading a diff](/guides/reading-a-diff) explains every kind of note.

### A question gets an answer

A note with a `?` in it is a question. The agent checks the code before
answering, and tells you what the answer changed, if anything. A question never
posts.

```text
 your note    why not reuse parseConfig here?

 2.0          💡 Comment to @author: "Why not reuse parseConfig here?"
              …on its way to the CR under your name

 2.1          ❓ parseConfig throws on a missing key, and this path needs
                 the defaults. Nothing changed.
```

When only the CR's author knows the answer, the agent offers to ask them, as a
comment you approve. A pass whose only notes were questions counts as approved
once they're answered.

### Every reply can be found

- When two replies land on the same line, they arrive as one note. In 2.0 the
  second replaced the first.
- A reply with no line in the diff links to its own heading in
  `(context).md`, where 2.0 said *end of file*.
- A reply is one sentence. The diff beside it shows the change.

`/anchor:resolve-feedback` also links each thread in its triage table to the
thread on the forge.

### Hide the hints with one note

Leave a note such as *hide this* on the Review box's keys to turn the hints
off. That note doesn't count as feedback on your change. Each kind of review
keeps its own setting
([`anchor.hints`](/guides/configuring?id=key-hints)).

## Ending a review

### Quitting a batch asks you to confirm

In a batch edit, or the items pass of `/anchor:review`, quitting used to
publish nothing unless you knew to leave an `approve` note. Now <kbd>q</kbd>
always counts your answers and asks:

```text
╭──────────────────────────────────────────────────────────╮
│                                                          │
│                         Confirm                          │
│                                                          │
│                       accept     3                       │
│                       edit       1                       │
│                       skip       1                       │
│                                                          │
│            [Z Confirm]   Q Stop   Esc Go back            │
│                                                          │
│                  ←→ move  enter choose                   │
╰──────────────────────────────────────────────────────────╯
```

| Key | What happens |
| --- | --- |
| <kbd>Z</kbd> or <kbd>Enter</kbd> | publishes what you accepted |
| <kbd>Q</kbd> | stops, and nothing is published |
| <kbd>Esc</kbd> | goes back to the review, with your answers kept |

[Batch Editing](/guides/batch-editing?id=ending-the-review) walks through it.

### A shorter Review box

The Review box at the top of `(context).md` drops the `approve` note
instructions and the option to relaunch the review in your editor. You still
edit a file in place with <kbd>e</kbd>.

2.1:

```text
╭─ Review ──────────────────────────────────────────╮
│ `[` ← prev                             next → `]` │
│                                                   │
│ `a`   note this line                              │
│ `A`   note this file                              │
│                                                   │
│ `q`   done                                        │
│ `ZZ`  done, approve                               │
│ `ZQ`  done, reject                                │
│                                                   │
│ *Add a note on this line to dismiss these hints.* │
╰───────────────────────────────────────────────────╯
```

2.0:

```text
╭─ Review ─────────────────────────────────────────────────────────────────╮
│ `[` ← prev                                                    next → `]` │
│                                                                          │
│ To add an annotation:                                                    │
│ `a` to the current line                                                  │
│ `A` to the current file                                                  │
│                                                                          │
│ When you are done, leave a single note here saying `approve` or          │
│ `reject`, then quit with `q`. With no notes of your own, `ZZ` approves   │
│ and `ZQ` rejects:                                                        │
│ - `approve`: commit as drafted                                           │
│ - `reject`: stop, commit nothing                                         │
│ - **Relaunch in your editor**: leave a note on this line to quit revdiff │
│   and start this review over in your editor, where what you save is the  │
│   draft                                                                  │
│                                                                          │
│ Notes of any other kind go back for a revision you review again.         │
│                                                                          │
│ *Tell the agent "hide hints" to shrink this box to the choices.*         │
╰──────────────────────────────────────────────────────────────────────────╯
```

The first pass of `/anchor:review` now shows its own guide, which revdiff's
generic header used to replace.

### Arrow keys work on a stock Mac

Under macOS's bundled bash 3.2, every arrow key and click in the verdict box
read as <kbd>Esc</kbd>. They now work on any bash.

## Upgrading from 2.0

- **Hidden hints may come back in two places.** `anchor.diff.hints false` no
  longer covers the read pass of `/anchor:review` or batch reviews. Those have
  their own keys, `anchor.review-read.hints` and `anchor.items.hints`.
  `anchor.hints false` still hides the hints everywhere.
- **The review record in a CR description moves to a new shape.** The
  `anchor:review-status` comment now lists one commit per line. anchor reads
  a 2.0 record and rewrites it the next time it saves.

The rest of the release is in the
[changelog](https://github.com/chris-peterson/anchor/blob/main/CHANGELOG.md).
