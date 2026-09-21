## Step 3: Act

Work the dispositions in this order — code first, then talk:

### 3a. Apply code changes

Make the edits for every *fix* disposition. Group related fixes into one
commit; unrelated concerns get separate commits so each reply can cite a
focused SHA.

Keep each fix within the changeset's existing scope — the bundled guide
(`<anchor-root>/guides/changeset-scope.md`) has the bar and the surface-and-confirm move.

If the author flags something in the CR description as worth keeping,
fold it into the repo's docs as part of the fix commit — the bar and the
adaptation rules are in the bundled guide (`<anchor-root>/guides/description-vs-docs.md`).

### 3b. Test and commit

Run the project's test suite (same detection, exit-code gate, and silence on a
pass as `anchor:commit` Step 0); a failing suite blocks the push, no exceptions. Then commit **as new commits —
never amend** what the reviewer has seen: a CR with feedback on it is being
read, so the "changes since you last looked" diff is load-bearing regardless
of draft state. Subject names the concern, body cites the thread:

```text
Rename --force to --skip-validation

Addresses review feedback from @reviewer on deploy.sh:42 — "force"
implied more than the flag does.
```

Show the commit(s) for confirmation, then push (plain push — the branch only
gains commits).

That push starts a fresh pipeline on the fix, and telling the reviewer their
feedback is addressed reads differently if it went red. Launch the watch with
the host's background/session mechanism, retain its handle, and let it poll
while you carry on with 3c through 3e:

```bash
bash "<anchor-root>/scripts/pipeline-after-push.sh" --skill resolve-feedback
```

Its verdict belongs in Step 4's summary; read it there.

### 3c. Draft each reply, then get the wording approved

A reply posts through the user's own token, so it lands under their name with
nothing marking it as drafted by an agent. The reviewer reads it as the user
talking. That makes the words the user's to approve before they go out: a fix
they'd have written differently is still a fix, but a *sentence* they wouldn't
have written is one they now have to own on a thread other people are reading.

So draft every reply, show them, and post nothing until the user says the text
is right. Reply content:

- For fixes, the default is exactly this, and nothing more:

  ```text
  addressed in <commit-url>
  ```

  The commit message and diff carry the detail; restating it in the thread
  is noise, and prose explaining *why the reviewer was right* reads as
  defensive. Add a sentence only when the fix took a different direction
  than the reviewer suggested.
- For answers: the answer. If the question revealed something the code or
  docs should say, prefer fixing that and replying with the pointer.
- For defers: where the ask landed (issue/CR link).

Present them together, each body **verbatim** — the text as it will appear on
the thread, not a paraphrase of it. A summary hides exactly the thing the user
is being asked to approve:

| # | Where | Reply |
|---|-------|-------|
| 1 | `src/deploy.sh:42` | addressed in <url> |
| 2 | `taskdef.yml:7` | Fargate would mean rebuilding the image on every deploy — the EC2 launch type keeps the layer cache warm. |

Then ask with structured choices when the host supports that (header `Replies`),
or directly otherwise: **Post as drafted** / **Edit** (they name the numbers and
what to change; redraft and show the table again) / **Skip replying** (leave the
threads for a later round). One gate for the whole set, not one per thread — the
same approval asked N times reads as noise, and the user starts approving
without reading.

This is not the Step 2 gate. Step 2 settles *what happens to each thread*
while the words are still unwritten; approving a disposition is not approving
a sentence. A thread that comes back in feedback with a phrasing change never
returns to triage — it stays here.

### 3d. Post the approved replies

Write each approved body to a unique temp file (`$(mktemp -u /tmp/reply.XXXXXX).md`, whose literal `/tmp` a caller's path-scoped write grant reaches — `<anchor-root>/guides/temp-paths.md`)
and post it into the *existing* thread — not as a new top-level comment (see
the cookbook, "Reply to a review thread"). Post what was approved: an
improvement you notice while posting goes back through 3c, because the point of
the gate is that nothing reaches the thread the user hasn't read.

### 3e. Resolve

Resolve exactly the threads whose disposition included *resolve* (cookbook:
"Resolve / unresolve a review thread"). Verify each resolution call returned
`resolved: true` / `isResolved: true` — a silently-dropped resolution looks
identical to a forgotten one.

## Step 4: Summary

Report one line per thread: `#N <file:line> — <disposition> — <commit sha /
reply posted / resolved>`, plus anything deferred and where it went. If any
thread was skipped, say so — the next `anchor:resolve-feedback` run picks it
up.

Then close with the pipeline. Read the watch launched in 3b through the host's
command-session mechanism: `PIPELINE_WATCH=skipped` means a config key turned it
off or the commit's runs were already reported — say nothing more. `PIPELINE_WATCH=ran` is
followed by the lines `anchor:pipeline` reads; report them following
`<anchor-root>/templates/pipeline-report.md`. If it hasn't settled yet,
say the watch is still running and link the pipeline rather than waiting on it.
