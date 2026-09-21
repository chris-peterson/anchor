## Step 1: Gather the changeset

Run the gather script once. It performs Step 1's deterministic recon and the safe default-path setup — detect the forge, resolve the CR if one is already open, count the gap to the default branch, capture the current description as the Step 4 diff baseline, check local state against the CR head, read the project template and `anchor.*` config — then prints one `KEY=value` block on stdout:

```bash
bash "<anchor-root>/scripts/prepare-review.sh"
```

Read the block and act only on what it surfaces; don't re-run the individual probes. The keys:

| Key | What to do with it |
|-----|--------------------|
| `RESOLVED_VIA` | `cwd` (inferred from the working directory) or `repo` (an explicit `--repo` was honored) — see "Operating against a non-cwd repo" |
| `FORGE` | `github` / `gitlab` picks the CLI for the rest of the skill; `none` → the URL-free `skip-deep-links` path |
| `DEFAULT_BRANCH` | substitute for `main` in the diff/log commands below |
| `ON_DEFAULT_BRANCH=1` | HEAD is the default branch — there's no branch to open a CR *from*. With work to review, `NEEDS_BRANCH=1` routes through branch creation first; clean with nothing ahead → `NOTHING_TO_REVIEW=1` and the script exits 65 |
| `NOTHING_TO_REVIEW=1` | **The script exited 65.** There is no branch to open a CR from and nothing to put in one, so this flow does not apply here — report that and stop. Say it plainly: a chain that named `anchor:prepare-review` has lost its CR step, and the user needs to know *before* anything downstream (a merge, a release) runs. Never paraphrase it into "this step was moot" and continue |
| `AHEAD=0` | nothing ahead of the default branch — `NEEDS_COMMIT=1` chains to `anchor:commit` (see below); otherwise say so and stop |
| `NEEDS_BRANCH=1` | on the default branch with work to review — a feature branch must exist before a CR can be opened (see "Get to a reviewable, pushed commit") |
| `NEEDS_COMMIT=1` | no reviewable commit yet — chain into `anchor:commit` before continuing (see "Get to a reviewable, pushed commit") |
| `NEEDS_PUSH=1` | commits are ahead, no CR yet, but the branch isn't pushed — chain into `anchor:commit`, which commits and pushes, then re-gather (see "Get to a reviewable, pushed commit") |
| `BEHIND=<n>` | `>0` → run the rebase dialog below |
| `CR_URL` / `CR_IID` | an already-open CR — the write target. Empty on `CR_PENDING` and on `skip-deep-links` |
| `CR_PENDING=1` | no CR is open and one can be. Draft, review, *then* open it in Step 4 — nothing is published under the author's name until they have approved the text |
| `CR_DRAFT` | gates the post-rebase force-push (see below) |
| `PRIOR_CR_IID` / `PRIOR_CR_STATE` | non-empty → the branch name already carries a CR that isn't open, which this run passed over; name it once (see "A reused branch name") |
| `STATE` | `match` → proceed; anything else → surface and stop (see "Act on `STATE`") |
| `CURRENT_DESC_PATH` | the review's left-hand side in Step 4 — an empty file until a CR holds a description |
| `DESC_DRAFT_PATH` | where to write the drafted description in Step 4 — already `mktemp`'d, so don't make your own |
| `TEMPLATE_PATH` | the CR template to compose into (Step 3); empty when the hierarchy holds none, or when the pick needs the author |
| `TEMPLATE_SOURCE` | which level answered — `local` / `project-settings` / `inherited` / `configured` / `ambiguous` / `none` |
| `TEMPLATE_CANDIDATES` | `ambiguous` only — `[{name, path}]` for the author to pick from (see "Honor an existing forge template") |
| `DELETE_BRANCH_ON_MERGE` | `false` on a CR this run opened → name it and offer the remediation (see "Branch deletion on merge"); `unknown` → say nothing |
| `ANCHOR_CONFIG` | `anchor.*` keys to apply (Step 3), as JSON |

If the block carries a `CR_CREATE_ERROR=…` line, the draft-open hit an auth or push failure — surface it and ask the user to refresh credentials; do **not** fall back to the URL-free path (the fail-fast-on-auth rule).

### Operating against a non-cwd repo

When the CR lives in a repo other than the session's cwd (you're in repo A, the CR is in repo B), don't drive B off cwd. **With B given as a name** — "open the MR in `customer-svc`" — resolve it with `<anchor-root>/scripts/resolve-target.sh <name>` (see the cookbook's "Resolving a named target repo") and act on `TARGET_VIA`:

- **One match** — use `TARGET_LOCAL` as B's checkout. Opening a CR needs a work tree (there has to be a branch to push), so when `TARGET_LOCAL` is empty, ask where the checkout lives rather than proceeding.
- **`ambiguous`** — prompt with `TARGET_CANDIDATES`, then use the chosen entry.
- **`cwd`** — the name matched nothing. **Don't open a CR in the cwd repo when the user named a different one**: say the name didn't resolve and ask for an explicit `--repo <path>`. This flow writes — it opens a CR, describes it, and may rebase and force-push — so a silent fall-back publishes work against a repo nobody named.

**With B given as a path**, that path is the checkout; there's nothing to resolve.

Either way, thread the checkout through every later command — the harness resets cwd between Bash calls, so each one needs it again: `prepare-review.sh --repo <path>`, `git -C <path>`, `-R <owner/name>` on `gh`/`glab` subcommands, and the URL-encoded project for `:fullpath` (plus `--hostname <host>`) on `glab api`, which has no `-R`. The full threading rules are in `<anchor-root>/guides/forge-cookbook.md`.

`--cr <iid|url>` resolves a CR that isn't the checkout's branch — updating an MR while the checkout sits on a WIP branch. The deep-link and diff steps still read the checkout's branch, so point `--repo` at a checkout on the CR's branch when you need those.

When the target is just the session cwd (no non-cwd repo in play), skip all of this — everything below is plain `git` / `gh` / `glab` against the working directory.
