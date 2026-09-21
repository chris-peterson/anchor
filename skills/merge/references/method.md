## Step 2: Choose the merge method

Land the branch's commits as they stand, with a **merge commit** that preserves
every commit on the branch (git's `--no-ff`). This is the method — don't read the
commits to second-guess it. Whether the branch is one commit or twenty, tidy or
noisy, is the author's history to keep; collapsing it isn't this skill's call. The
method changes only when the project or CR is **configured** for a different one.

Read that configuration and let it override the default:

**GitLab** — the project pins the merge method; the MR pins the squash choice
(cookbook: "Merge a CR"):

```bash
glab api projects/:fullpath | jq '{merge_method, squash_option}'
glab mr view <iid> --output json | jq '{squash}'
```

- `merge_method`: `merge` → merge commit, the default (no override). `ff` →
  fast-forward, no merge commit (the project mandates a linear history).
  `rebase_merge` → semi-linear.
- `squash_option`: `always` → squash (the project requires it). `never` → don't
  squash. `default_on` / `default_off` → the author's per-MR `squash` checkbox
  decides; honor the MR's `squash` field.

**GitHub** — the repo pins which strategies are allowed; there's no enforced
default beyond that (cookbook: "Merge a CR"):

```bash
gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed
```

Use `--merge` when merge commits are allowed. Only when the repo disables them
does the method change — fall to the allowed strategy that still keeps the commits
(`--rebase`) ahead of the one that discards them (`--squash`).

Then **preview and confirm** — state what will happen and take a yes/no; don't
offer a method menu. When the method is the merge-commit default:

> Merging `!42` into `main` via merge commit (preserves 3 commits). Proceed?
> `[yes / no]`

When a setting moved it off the default, name the setting so the deviation is
visible:

> The project's merge method is fast-forward — merging `!42` into `main`
> fast-forward, no merge commit. Proceed? `[yes / no]`

On `no`, stop and don't merge. The method follows the default and the forge's
settings, not an inline menu — so to land it differently the user either adjusts
the project/CR settings (and you re-read them) or names the method to use. On
`yes`, merge.

**The prompt is this step's whole output.** `merge_method`, `squash_option`, the
MR's squash flag, the allowed strategies: each is input to the prompt, never a
paragraph ahead of it. A setting that left the default standing is nothing to
report — say what the merge will do, not which settings declined to change it.
Where a setting *did* move the method, the prompt above already names it, which
is where it belongs.
