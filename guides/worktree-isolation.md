# Operating against a non-cwd repo (worktree isolation)

How `/anchor:create-review` targets a CR that lives in a repo other than the
session's working directory. When the target *is* just the session cwd, none of
this applies — run everything as plain `git` / `gh` / `glab` against the working
directory.

When the CR you're preparing lives in a repo other than the session's working directory — you're in repo A, the CR is in repo B — don't drive B off cwd.

If you have B as a *name* rather than a path, resolve it first: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-target.sh" <name>` (cookbook: "Resolving a named target repo"). Act on `TARGET_VIA`:

- **`tack`** → use `TARGET_LOCAL` as the `<path-to-B-checkout>` below. Opening a CR needs a checkout (there must be a branch to push), so if `TARGET_LOCAL` is empty — a known remote with no local clone — ask for a checkout rather than proceeding.
- **`ambiguous`** → prompt with `TARGET_CANDIDATES`, then use the chosen entry.
- **`cwd`** (no tack, or the name didn't match) → the name couldn't be resolved to a checkout. **Don't** silently prepare a review in the cwd repo when the user named a *different* one — say the name didn't resolve and ask for an explicit `--repo <path>`. (When no name was in play to begin with, this whole section doesn't apply — that's just the cwd path.)

Then decide direct-vs-isolated **once, up front**, with the lifecycle helper:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree.sh" setup <path-to-B-checkout>
```

It prints `RESOLVED_VIA`, `WORKTREE`, and `CHECKOUT`:

- **`RESOLVED_VIA=repo`** — B is the same repo as the session cwd (or a sibling worktree of it); operate directly. `<CHECKOUT>` is B's path.
- **`RESOLVED_VIA=worktree`** — B is a *different* repo, so the helper made a throwaway worktree at `WORKTREE`, checked out on B's current branch. Working there never disturbs B's own checkout, and it dodges the `glab mr create -R` 422 (the create runs *inside* the worktree, not with a `-R` glab ignores). `<CHECKOUT>` is the worktree.

`<CHECKOUT>` is the path to operate in either way. **The harness resets cwd between Bash calls, so nothing persists implicitly** — thread the target through every later command:

- **Re-gather** — `create-review.sh --worktree <WORKTREE>` (isolated) or `--repo <CHECKOUT>` (direct), plus `--cr` if you set one.
- **git** — `git -C <CHECKOUT> …`: the diff/log reads, the rebase, `git push --force-with-lease`.
- **gh / glab subcommands** — `-R <owner/name>` (derive once from `git -C <CHECKOUT> remote get-url origin`).
- **`glab api`** — has no `-R`; substitute the URL-encoded project for `:fullpath` (e.g. `group%2Fproject`), plus `--hostname <host>` for self-hosted GitLab.

**Tear the worktree down when the flow ends** — after the CR is opened and described, or on abort. It's throwaway; leaving it strands a checkout on B's branch:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree.sh" teardown <path-to-B-checkout> <WORKTREE>
```

(Skip teardown on the `repo` / direct path — there's no worktree, `WORKTREE` is empty.)

To act on a CR that isn't the checkout's branch (updating an MR while the checkout sits on a WIP branch), add `--cr <iid|url>` so the script resolves that CR instead of the branch's. The deep-link and diff steps still read the checkout's branch, so point setup at a checkout on the CR's branch when you need those.
