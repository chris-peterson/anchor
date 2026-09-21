## Step 1: Resolve and fetch the change request

**Target repo.** Resolve it as the other `anchor` skills do. **With a name
argument**, resolve it with
`<anchor-root>/scripts/resolve-target.sh <name>`: `TARGET_VIA=resolved` →
pass `TARGET_LOCAL` as `--repo`; empty `TARGET_LOCAL` → ask where the checkout
lives; `ambiguous` → prompt with `TARGET_CANDIDATES`; `cwd` → the working
directory's repo. **With a CR URL**, the URL names the project — if that project
isn't the cwd repo, resolve its checkout the same way before continuing. This
skill reads a work tree, so it needs one.

Then gather everything in one call:

```bash
bash "<anchor-root>/scripts/review-cr.sh" <number|url|branch> [--repo <path>]
```

With no argument it resolves the open CR for the current branch. Read the block
and act only on what it surfaces:

| Key | What to do with it |
|-----|--------------------|
| `FORGE` / `HOST` / `PROJECT` | pick the CLI and target it; `HOST` is `glab --hostname` on self-hosted GitLab |
| `CR_IID` / `CR_URL` / `CR_TITLE` / `CR_AUTHOR` | the one line you report, and the header for Step 3's viewer |
| `CR_STATE` | anything but `open` → say what state it's in and ask before continuing; a merged CR takes comments but nobody is waiting on them |
| `CR_DRAFT=true` | on someone else's CR the author hasn't asked for review yet — say so and confirm before spending their attention. In self-review it is the expected state and needs no comment |
| `IS_OWN_CR=1` | the CR is the user's own, so this runs as a **self-review** (Step 5). Say which mode you're in once, and don't ask them to confirm reviewing their own change |
| `CR_HEAD_SHA` / `CR_BASE_SHA` / `CR_START_SHA` | pinned at fetch time; Step 7 passes them back so every anchor lands on the diff that was actually read |
| `DIFF_RANGE` | what Step 3 hands the viewer — the **whole** range, never a subset |
| `CHANGED_FILES` | the size of what's being reviewed |
| `DESC_PATH` | the description, for Step 2 |
| `DIFF_PATH` | the unified diff, for your own read in Step 4 |
| `FINDINGS_PATH` | where the findings JSON goes; already seeded and `mktemp`'d, so don't make your own |

A `REVIEW_ERROR=…` line means there is nothing to review — surface it and stop.
On a 401/403 the same line carries the auth failure: ask the user to refresh
credentials rather than retrying or reaching for another endpoint.

## Step 2: Read the description before the diff

Read `DESC_PATH` first, in full. The description states what the change is *for*,
and that is what decides whether the diff is a good answer — a reviewer who
starts in the diff can only check whether the code is internally consistent,
which is the cheaper half of the job. `anchor` spends a whole skill making that
description worth reading; use it.

Take from it: the problem the author says they're solving, the approach they
chose, anything they flagged as contested or unverified, and any Review guide
pointing at where they want attention. Note what the description **doesn't**
answer — a change whose reason is missing is itself a finding, and a better one
than most line-level remarks.

Then read `DIFF_PATH` against that. Where the diff does something the
description doesn't account for, that gap is the highest-value thing you have.
