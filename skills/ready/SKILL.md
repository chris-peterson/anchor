---
name: ready
description: Mark a draft change request ready for review. Clears its draft flag, requests the reviewers you name, and reports where its pipeline stands. Use when marking a PR/MR ready, taking it out of draft, un-drafting it, or saying "it's ready for review".
---

# Ready

Take a draft change request out of draft so reviewers know it's theirs to look
at. `anchor` opens every CR as a draft (`/anchor:prepare-review`), and
`/anchor:review` offers this step when a self-review ends; `/anchor:ready` is
the direct route when the author has decided without one.

**Don't narrate your work.** Follow `${CLAUDE_PLUGIN_ROOT}/guides/execute-quietly.md`.
The things worth surfacing are a question that needs the user, the CR marked
ready, its pipeline, and the next step.

The invocation is the author's decision that the change is ready. Ask only where
the state below says the CR isn't what they'd expect to hand over.

## Step 1: Read the CR

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mark-ready.sh" --check [--cr <number|url>] [--repo <checkout>]
```

With no `--cr` it reads the branch's open CR. Pass `--cr` when the user named
one, and `--repo` when it lives in a checkout other than the working directory
(resolve a repo given by name with `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-target.sh`,
as the forge cookbook's "Resolving a named target repo" describes).

| Key | What to do with it |
|-----|--------------------|
| `READY_ERROR=…`, exit 65 | the branch has no open CR, or the named one is merged or closed. Say so and stop; point at `/anchor:prepare-review` when the branch has none |
| `READY_ERROR=…`, exit 70 | the forge couldn't be read. Surface it; on an auth failure ask the user to refresh credentials, and don't retry |
| `CR_DRAFT=false` | already ready. Say so, then go to Step 3 for reviewers and the pipeline |
| `LOCAL_STATE=dirty` | uncommitted changes in the checkout, so the CR may be missing work. Ask (header `Ready`): **Mark ready anyway** or **Stop** (point at `/anchor:commit`) |
| `LOCAL_STATE=head-mismatch` | the checkout's HEAD isn't the CR's head: commits not pushed yet, or a push someone else made. Ask the same question, naming the two SHAs |
| `LOCAL_STATE=ok` / `elsewhere` | proceed |

## Step 2: Clear the draft flag

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mark-ready.sh" --forge <FORGE> --cr <CR_NUMBER> [--repo <checkout>]
```

It reads the flag again rather than trusting Step 1, saves the CR under
`.git/anchor/backups/` first, and announces `cr.ready`. `CR_READY=ok` is the
transition; `ALREADY_READY=1` means someone got there between the two calls, so
say that rather than claiming this run did it.

## Step 3: Reviewers, then the pipeline

**Reviewers.** When the user named any (`/anchor:ready @alice`, "ready, and ask
Bob"), request them with the calls in the forge cookbook's "Mark a CR ready, and
request reviewers" (`${CLAUDE_PLUGIN_ROOT}/guides/forge-cookbook.md`); on GitLab
add with `+` so existing reviewers stay. Otherwise don't ask: requesting
reviewers is a separate decision, and the forge's own assignment rules may
already cover it.

**Pipeline.** Report where the CR head's pipeline stands, read once:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pipeline-status.sh" --sha <CR_HEAD_SHA> [--repo <checkout>]
```

A reviewer opening a CR with a red pipeline reviews code that may change, so a
`failed` state is worth one line with the failing jobs from
`PIPELINE_FAILED_JOBS`.

## Report

One line naming the CR (`CR_REF` linked to `CR_URL`) and what changed, then the
pipeline and the reviewers requested, then the next step: `/anchor:merge` once
the reviews are in, or `/anchor:resolve-feedback` when threads come back.

> `widget#128` is ready for review, with @alice requested. Pipeline: running on
> `abc1234`. Next: `/anchor:merge` once it's approved.
