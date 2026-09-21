## Step 5: Watch the pipeline the merge triggered

The merge writes a commit to the default branch, and for most repos that commit
is what deploys, publishes, or releases. The branch pipeline the gates read
proved the change in isolation; the target branch's is the one that says it
landed. Don't leave it unwatched and make the user think to ask.

The watch blocks while it polls, so launch it with the host's background/session
mechanism once Step 4's cleanup is done, retain its handle, and read captured
stdout through that mechanism when it completes:

```bash
bash "<anchor-root>/scripts/pipeline-after-push.sh" --skill merge --sha <landed sha>
```

Pass the landed sha you read back in Step 3 rather than letting the helper take
HEAD: a squash lands a commit the local branch never had, and a `--ff-only` pull
that couldn't fast-forward leaves HEAD elsewhere. Retarget a non-cwd checkout
with `--repo <checkout>`, same as the other helpers.

Nothing about *whether* to watch is decided here — the helper owns it:

- **`PIPELINE_WATCH=skipped`** → `PIPELINE_WATCH_REASON` says `config-off`
  (`anchor.merge.watchPipelineAfterPush`, or the umbrella key) or
  `already-reported`. Either way there's nothing to report; end the flow silently.
- **`PIPELINE_WATCH=ran`** → the same `KEY=value` lines `anchor:pipeline` reads
  follow it. Report them following
  `<anchor-root>/templates/pipeline-report.md`, including its "After a
  push" notes — the headline carries `<target>`, not the branch just deleted.

Step 6's result goes out while this polls, so the flow is never held open; the
pipeline report lands when the watch settles.

## Step 6: Report

One line: `Merged <CR ref> into <target> (<method>) — <merge-sha>`, with the CR URL.
Note the branch cleanup only if it needed the user's attention (a `-d` that refused).
Nothing more — the merge is the outcome, not a status report.

**A noisy line in a forge CLI's output is not a finding.** `glab mr merge` prints
`! No pipeline running on <branch>` when it looks for an in-flight pipeline to
wait on and finds none, which reads alarming and means nothing. The user never
saw it — the terminal collapsed that tool result — so explaining it invents a
confusion to resolve. Surface such a line only where it changed the outcome.

Where the repo has something to publish, close with `anchor:release` as the next
step — one clause, not a pitch, and don't run it. On a repo with no version
artifact (`RELEASE_MODEL=no-version-artifact` — the merge *was* the release), leave
it out entirely rather than pointing at a skill that would no-op.
