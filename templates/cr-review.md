# Review document template

The shape of a review: what the document holds, what a single finding says, and
where each finding ends up on the change request. The `review` skill owns the
*technique* — resolving the CR, driving the diff viewer, gating the post. This
file owns the *shape*, so it's the place to edit as your preferences evolve.

A review's raw material is someone else's change and the reason they gave for
it. The author already wrote *why* in the description; the review's job is to
say whether the diff is a good answer to that why, and to put each specific
remark on the line it is about.

**A review document is local until you say otherwise.** It is drafted, read, and
revised in the session, and reaching the CR is a separate act the author of the
review approves. Reviewing without posting is a finished outcome, not an
abandoned one.

## The document

```markdown
## <CR title>  (<forge ref> · <author>)

<Summary — the overall read, two or three sentences.>

### Findings

1. `<path>:<line>` — <what is wrong or worth asking, and why it matters>
2. `<path>:<line>` — …

### Not anchored to a line

- <a remark about the changeset as a whole, or about a file>
```

The **Summary** is the part the author reads first and the only part that
survives if they read nothing else. Say whether the change does what its
description claims, and name the one thing most worth their attention. It is not
a verdict — recording approval or requesting changes on the forge is the human
reviewer's own act, never the skill's.

**Findings** are numbered so they can be discussed and posted individually. The
number is the document's, not the forge's.

## What a finding says

Each finding carries a file, a line, and a body. The body is what lands in the
thread, so write it as the thing you would type into the CR:

- **State the consequence, not the observation.** *"This drops the tenant from
  the cache key, so two tenants share an entry"* gives the author something to
  act on; *"cache key changed"* restates the diff they wrote.
- **One concern per finding.** Two concerns on one line are two findings; the
  author resolves them separately.
- **Ask when it is a question.** A reviewer who does not know why a choice was
  made asks; a reviewer who is confident says so plainly. Both are useful, and a
  question dressed as a demand wastes a round trip.
- **Point at the alternative when there is one**, in one clause. A finding that
  only says *no* leaves the author to guess what *yes* looks like.
- **Skip what the diff already shows.** The author can see which files changed.

The register is the same one `anchor` uses everywhere: plain words, no loaded
framing (`${CLAUDE_PLUGIN_ROOT}/guides/loaded-framing.md`), no size-minimizers,
no praise padding. Findings go out under the reviewer's name and read as the
reviewer talking.

## Where each finding lands

| Finding | On the CR |
|---|---|
| a file and a line | an inline thread anchored to that line |
| a file, no line | the summary comment, named with its file |
| the changeset as a whole | the summary comment |

**Nothing is dropped for want of an anchor.** A remark that cannot be pinned to
a line is still the remark; it moves to the summary comment rather than
disappearing. Both forges take line anchors the same way, so which findings can
be anchored does not depend on where the CR lives.

## Findings the reviewer typed themselves

Comments made in the diff viewer arrive in the same shape as the ones the skill
drafts, and both are findings. Keep the reviewer's wording verbatim — it is
already the sentence they wanted to send, and rewriting it into a house voice
replaces the thing they approved with something they did not.

Where the two overlap — the reviewer and the skill flagged the same line — keep
the reviewer's and drop the duplicate rather than posting the line twice.
