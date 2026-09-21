## Step 4: Examine the diff against each quality

**Read `<anchor-root>/templates/review-qualities.md` before the
examination, not after.** It lists the qualities a review weighs and the
instruction their findings come back in. It is the user's file to edit, so the list as it stands is
the review's scope: don't weigh a quality it doesn't list, and don't skip one it
does.

**One agent per listed quality**, launched in a single message so they run
concurrently. Each gets the pinned diff (`DIFF_PATH`), what Step 2 established
the change is *for*, one quality's name and wording verbatim, and the template's
output instruction — nothing about the other qualities. Independent lenses are
the point; one pass over the whole list blurs them, which is most of why the list
is worth enumerating. Cost scales with it: four qualities is four agents, ten is
ten.

Then merge everything into one set:

- **The reviewer's own comments are findings**, kept **verbatim**. That sentence
  is already the one they wanted to send, and rewriting it into a house voice
  replaces what they approved with something they didn't.
- **On a line carrying both**, keep the reviewer's and drop the agent's rather
  than posting the line twice.
- **Two agents on the same line for the same reason is one finding** — keep the
  more specific and drop the rest.

### Where each finding goes

Put each remark at the **narrowest location that carries it**:

| Finding | Where it lands |
|---|---|
| a file and a line | an inline thread anchored to that line |
| a method or hunk, no single line | a thread on the line that opens it |
| a file, no line | the summary comment, named with its file |
| the changeset as a whole | the summary comment |

**Nothing is dropped for want of an anchor.** A `file` or `changeset` target
folds into the summary comment — that fallback is the script's, so state the
concern where it belongs and let the rendering place it. Both forges take line
anchors the same way, so which findings can be anchored doesn't depend on where
the CR lives.

### What a finding says

The body is what lands in the thread, so write it as the thing the reviewer would
type into the CR:

- **State the consequence, not the observation.** *"This drops the tenant from
  the cache key, so two tenants share an entry"* gives the author something to
  act on; *"cache key changed"* restates the diff they wrote.
- **One concern per finding.** Two concerns on one line are two findings; the
  author resolves them separately.
- **Ask when it is a question.** A question dressed as a demand wastes a round
  trip.
- **Point at the alternative when there is one**, in one clause. A finding that
  only says *no* leaves the author to guess what *yes* looks like.
- **Skip what the diff already shows.** The author can see which files changed.

The register is `anchor`'s everywhere: plain words, no loaded framing
(`<anchor-root>/guides/loaded-framing.md`), no size-minimizers, no praise
padding. Findings go out under the reviewer's name and read as the reviewer
talking.

The **summary** says whether the change does what its description claims and
names the one thing most worth attention. It is not a verdict — recording
approval or requesting changes on the forge is the human reviewer's own act
(Step 8).

### Write it out

Write the findings to `FINDINGS_PATH` as JSON, then read it back rendered. The
entries use the DIFF contract's comment shape, so a comment the user typed in
the viewer and one an agent wrote are the same kind of object:

```json
{
  "cr": {"url": "<CR_URL>", "headSha": "<CR_HEAD_SHA>"},
  "summary": "the overall read",
  "comments": [
    {"body": "…", "target": "line", "file": "src/cache.js",
     "startLine": 42, "endLine": 42, "side": "new", "origin": "reviewer"}
  ]
}
```

Keep `cr.headSha` exactly as Step 1 pinned it — Step 7 checks it. Set `origin`
to `reviewer` for anything the user typed in the viewer and `agent` for a
finding the fan-out produced.

Render the findings and revise them with the user until they say what they mean:

```bash
bash "<anchor-root>/scripts/review-post.sh" --preview --findings <FINDINGS_PATH>
```

Its output is the review — put it in your reply, since a Bash result reaches you
and not the user. Iterate here as many rounds as the user wants; nothing has
left the session yet.
