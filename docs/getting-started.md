# Getting started

Two decisions stand between a fresh install and your first commit: what `anchor`
may reach on your forge, and how much it may do without stopping to ask you.
Neither needs a configuration file, and you can change your mind on the second
one any day.

## Sign in to your forge

`anchor` never asks you for a token and never stores one. It shells out to your
forge's own CLI, and that CLI holds the credential in your operating system's
keychain.

```bash
gh auth login      # GitHub remotes
glab auth login    # GitLab remotes
```

Both default to a browser sign-in. The CLI gets its own token, puts it in the
keychain, and refreshes it for you: nothing to create, paste, or rotate by hand.
Take that path unless your organization has turned it off. On a machine with no
browser, `glab auth login --device` prints a code you approve from your phone.

### If you have to use a personal access token

This is the floor each CLI documents for itself:

| Forge | Scopes | Note |
|---|---|---|
| GitHub, classic token | `repo`, `read:org`, `gist` | `gh`'s stated minimum. `anchor`'s own calls are all repository ones; `gist` is `gh`'s floor, not `anchor`'s. |
| GitHub, if your commits touch `.github/workflows/` | add `workflow` | GitHub refuses a push that adds or edits a workflow file without it, and the error names the branch rather than the scope. |
| GitLab | `api`, `write_repository` | `glab`'s stated minimum. |

On GitHub, feed `gh auth login --with-token` a *classic* token. `gh`'s own help
warns that a fine-grained token's per-resource scoping behaves confusingly
through that path, and points you at the `GH_TOKEN` environment variable instead.

### What `anchor` can reach with it

Everything below is a call `anchor` actually makes. There is no broader
permission it holds in reserve.

| | |
|---|---|
| **Reads** | change requests and their diffs, issues, labels, milestones, pipeline runs, releases |
| **Writes** | opens and edits a change request, posts review comments and replies, marks a CR ready, merges an approved one, files and edits issues, publishes a release, dispatches your release workflow |
| **Changes about your repo** | one setting, and only when you say yes: GitHub's repo-wide *delete branch on merge*, offered when a CR has no other way to clean up its branch |
| **Never** | deletes a repository, touches members or permissions, force-pushes a change request that has been marked ready for review |

## Go at your own pace

Two dials control how much rope `anchor` has, and you set both.

| Dial | Where it lives | Narrowest useful setting |
|---|---|---|
| What it can reach on your forge | your token's scopes | read-only scopes |
| What runs without stopping to ask you | your Claude Code permission settings | nothing, so every step waits for an answer |

Neither is a one-way door. Widen one when the prompts start to feel like
ceremony. Narrow it again the day something surprises you.

**A read-only start is a real start.** `commit` still reads the diff, still
reviews it with you, still drafts the message. It stops at the prompt for the
commit itself and you answer that. What you give up is keystrokes, not
capability.

What makes widening comfortable later is the same thing that makes a narrow
setting bearable now: every skill puts the exact text in front of you before
anything lands. A `git commit` you read first is a different animal from one you
did not.

Here is one developer's second dial over seven months, as an illustration rather
than a schedule. It climbed as habits formed, dropped sharply when a change in
tooling made most of it unnecessary, and has drifted back up since.

<!-- Counts come from the permissions.allow array across the commit history of
     one Claude Code settings.json. Redrawn by walking that history; the shape is
     the point, not the exact values. -->
<svg viewBox="0 0 900 330" width="100%" role="img" xmlns="http://www.w3.org/2000/svg"
     aria-label="One developer's count of commands allowed to run without asking, March to September 2026: it rises through the spring, drops sharply in July, then settles"
     style="max-width:100%;height:auto;font-family:inherit">
<line x1="48" y1="268.0" x2="870" y2="268.0" stroke="var(--muted-color,#5a6896)" stroke-width="1" opacity=".15"/>
<text x="39" y="272.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="end">0</text>
<line x1="48" y1="204.6" x2="870" y2="204.6" stroke="var(--muted-color,#5a6896)" stroke-width="1" opacity=".15"/>
<text x="39" y="208.6" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="end">40</text>
<line x1="48" y1="141.1" x2="870" y2="141.1" stroke="var(--muted-color,#5a6896)" stroke-width="1" opacity=".15"/>
<text x="39" y="145.1" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="end">80</text>
<line x1="48" y1="77.7" x2="870" y2="77.7" stroke="var(--muted-color,#5a6896)" stroke-width="1" opacity=".15"/>
<text x="39" y="81.7" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="end">120</text>
<text x="60.0" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">Mar</text>
<text x="171.3" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">Apr</text>
<text x="294.6" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">May</text>
<text x="422.0" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">Jun</text>
<text x="545.3" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">Jul</text>
<text x="672.7" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">Aug</text>
<text x="800.1" y="289.0" font-size="11.5" fill="var(--muted-color,#5a6896)" text-anchor="middle">Sep</text>
<polygon points="48.0,236.3 52.1,236.3 52.1,236.3 56.2,236.3 56.2,212.5 60.3,212.5 60.3,201.4 76.8,201.4 76.8,198.2 80.9,198.2 80.9,199.8 85.0,199.8 85.0,199.8 89.1,199.8 89.1,199.8 93.2,199.8 93.2,199.8 97.3,199.8 97.3,199.8 101.4,199.8 101.4,199.8 105.5,199.8 105.5,196.6 109.7,196.6 109.7,193.5 113.8,193.5 113.8,193.5 117.9,193.5 117.9,187.1 122.0,187.1 122.0,185.5 126.1,185.5 126.1,184.0 130.2,184.0 130.2,184.0 134.3,184.0 134.3,182.4 138.4,182.4 138.4,176.0 142.5,176.0 142.5,176.0 146.6,176.0 146.6,176.0 150.8,176.0 150.8,176.0 154.9,176.0 154.9,176.0 159.0,176.0 159.0,176.0 163.1,176.0 163.1,176.0 167.2,176.0 167.2,176.0 171.3,176.0 171.3,172.9 175.4,172.9 175.4,172.9 179.5,172.9 179.5,168.1 183.6,168.1 183.6,168.1 187.7,168.1 187.7,168.1 191.8,168.1 191.8,164.9 196.0,164.9 196.0,161.8 200.1,161.8 200.1,163.3 204.2,163.3 204.2,161.8 208.3,161.8 208.3,163.3 249.4,163.3 249.4,163.3 253.5,163.3 253.5,163.3 257.6,163.3 257.6,163.3 261.7,163.3 261.7,163.3 265.8,163.3 265.8,163.3 269.9,163.3 269.9,163.3 278.2,163.3 278.2,163.3 282.3,163.3 282.3,163.3 286.4,163.3 286.4,163.3 290.5,163.3 290.5,163.3 294.6,163.3 294.6,160.2 298.7,160.2 298.7,160.2 306.9,160.2 306.9,160.2 311.0,160.2 311.0,160.2 315.2,160.2 315.2,160.2 319.3,160.2 319.3,157.0 323.4,157.0 323.4,144.3 327.5,144.3 327.5,144.3 335.7,144.3 335.7,141.1 339.8,141.1 339.8,138.0 343.9,138.0 343.9,136.4 348.0,136.4 348.0,101.5 352.1,101.5 352.1,101.5 356.2,101.5 356.2,106.3 360.4,106.3 360.4,106.3 364.5,106.3 364.5,88.8 368.6,88.8 368.6,88.8 372.7,88.8 372.7,88.8 376.8,88.8 376.8,88.8 380.9,88.8 380.9,88.8 385.0,88.8 385.0,88.8 389.1,88.8 389.1,88.8 393.2,88.8 393.2,88.8 397.3,88.8 397.3,88.8 401.5,88.8 401.5,87.2 405.6,87.2 405.6,87.2 413.8,87.2 413.8,80.9 417.9,80.9 417.9,80.9 422.0,80.9 422.0,85.6 426.1,85.6 426.1,85.6 430.2,85.6 430.2,85.6 434.3,85.6 434.3,85.6 438.4,85.6 438.4,85.6 442.6,85.6 442.6,84.1 446.7,84.1 446.7,80.9 450.8,80.9 450.8,80.9 454.9,80.9 454.9,80.9 459.0,80.9 459.0,80.9 463.1,80.9 463.1,80.9 467.2,80.9 467.2,80.9 475.4,80.9 475.4,82.5 479.6,82.5 479.6,82.5 487.8,82.5 487.8,65.0 491.9,65.0 491.9,66.6 496.0,66.6 496.0,66.6 500.1,66.6 500.1,66.6 504.2,66.6 504.2,65.0 508.3,65.0 508.3,65.0 512.4,65.0 512.4,65.0 516.5,65.0 516.5,73.0 520.6,73.0 520.6,73.0 524.8,73.0 524.8,73.0 528.9,73.0 528.9,73.0 533.0,73.0 533.0,73.0 537.1,73.0 537.1,73.0 541.2,73.0 541.2,73.0 545.3,73.0 545.3,73.0 549.4,73.0 549.4,73.0 553.5,73.0 553.5,73.0 561.8,73.0 561.8,73.0 565.9,73.0 565.9,73.0 570.0,73.0 570.0,73.0 574.1,73.0 574.1,73.0 578.2,73.0 578.2,73.0 582.3,73.0 582.3,73.0 586.4,73.0 586.4,73.0 590.5,73.0 590.5,73.0 594.6,73.0 594.6,73.0 598.7,73.0 598.7,73.0 602.9,73.0 602.9,73.0 607.0,73.0 607.0,73.0 611.1,73.0 611.1,73.0 615.2,73.0 615.2,73.0 623.4,73.0 623.4,73.0 627.5,73.0 627.5,229.9 631.6,229.9 631.6,229.9 635.7,229.9 635.7,229.9 639.8,229.9 639.8,233.1 643.9,233.1 643.9,233.1 652.2,233.1 652.2,233.1 656.3,233.1 656.3,233.1 660.4,233.1 660.4,233.1 664.5,233.1 664.5,233.1 668.6,233.1 668.6,233.1 672.7,233.1 672.7,233.1 676.8,233.1 676.8,233.1 680.9,233.1 680.9,233.1 685.1,233.1 685.1,233.1 689.2,233.1 689.2,233.1 693.3,233.1 693.3,233.1 697.4,233.1 697.4,233.1 701.5,233.1 701.5,233.1 705.6,233.1 705.6,231.5 709.7,231.5 709.7,231.5 713.8,231.5 713.8,228.4 717.9,228.4 717.9,226.8 722.0,226.8 722.0,226.8 730.3,226.8 730.3,226.8 738.5,226.8 738.5,209.3 742.6,209.3 742.6,209.3 746.7,209.3 746.7,209.3 750.8,209.3 750.8,209.3 754.9,209.3 754.9,204.6 759.0,204.6 759.0,204.6 767.2,204.6 767.2,204.6 771.4,204.6 771.4,207.7 779.6,207.7 779.6,207.7 783.7,207.7 783.7,207.7 787.8,207.7 787.8,207.7 791.9,207.7 791.9,207.7 796.0,207.7 796.0,207.7 800.1,207.7 800.1,207.7 804.2,207.7 804.2,207.7 808.4,207.7 808.4,207.7 812.5,207.7 812.5,207.7 820.7,207.7 820.7,207.7 837.1,207.7 837.1,207.7 841.2,207.7 841.2,207.7 845.3,207.7 845.3,207.7 849.4,207.7 849.4,207.7 853.6,207.7 853.6,207.7 857.7,207.7 857.7,207.7 861.8,207.7 861.8,207.7 865.9,207.7 865.9,207.7 870.0,207.7 870.0,268.0 48,268.0" fill="var(--theme-color,#7c3aed)" opacity=".13"/>
<polyline points="48.0,236.3 52.1,236.3 52.1,236.3 56.2,236.3 56.2,212.5 60.3,212.5 60.3,201.4 76.8,201.4 76.8,198.2 80.9,198.2 80.9,199.8 85.0,199.8 85.0,199.8 89.1,199.8 89.1,199.8 93.2,199.8 93.2,199.8 97.3,199.8 97.3,199.8 101.4,199.8 101.4,199.8 105.5,199.8 105.5,196.6 109.7,196.6 109.7,193.5 113.8,193.5 113.8,193.5 117.9,193.5 117.9,187.1 122.0,187.1 122.0,185.5 126.1,185.5 126.1,184.0 130.2,184.0 130.2,184.0 134.3,184.0 134.3,182.4 138.4,182.4 138.4,176.0 142.5,176.0 142.5,176.0 146.6,176.0 146.6,176.0 150.8,176.0 150.8,176.0 154.9,176.0 154.9,176.0 159.0,176.0 159.0,176.0 163.1,176.0 163.1,176.0 167.2,176.0 167.2,176.0 171.3,176.0 171.3,172.9 175.4,172.9 175.4,172.9 179.5,172.9 179.5,168.1 183.6,168.1 183.6,168.1 187.7,168.1 187.7,168.1 191.8,168.1 191.8,164.9 196.0,164.9 196.0,161.8 200.1,161.8 200.1,163.3 204.2,163.3 204.2,161.8 208.3,161.8 208.3,163.3 249.4,163.3 249.4,163.3 253.5,163.3 253.5,163.3 257.6,163.3 257.6,163.3 261.7,163.3 261.7,163.3 265.8,163.3 265.8,163.3 269.9,163.3 269.9,163.3 278.2,163.3 278.2,163.3 282.3,163.3 282.3,163.3 286.4,163.3 286.4,163.3 290.5,163.3 290.5,163.3 294.6,163.3 294.6,160.2 298.7,160.2 298.7,160.2 306.9,160.2 306.9,160.2 311.0,160.2 311.0,160.2 315.2,160.2 315.2,160.2 319.3,160.2 319.3,157.0 323.4,157.0 323.4,144.3 327.5,144.3 327.5,144.3 335.7,144.3 335.7,141.1 339.8,141.1 339.8,138.0 343.9,138.0 343.9,136.4 348.0,136.4 348.0,101.5 352.1,101.5 352.1,101.5 356.2,101.5 356.2,106.3 360.4,106.3 360.4,106.3 364.5,106.3 364.5,88.8 368.6,88.8 368.6,88.8 372.7,88.8 372.7,88.8 376.8,88.8 376.8,88.8 380.9,88.8 380.9,88.8 385.0,88.8 385.0,88.8 389.1,88.8 389.1,88.8 393.2,88.8 393.2,88.8 397.3,88.8 397.3,88.8 401.5,88.8 401.5,87.2 405.6,87.2 405.6,87.2 413.8,87.2 413.8,80.9 417.9,80.9 417.9,80.9 422.0,80.9 422.0,85.6 426.1,85.6 426.1,85.6 430.2,85.6 430.2,85.6 434.3,85.6 434.3,85.6 438.4,85.6 438.4,85.6 442.6,85.6 442.6,84.1 446.7,84.1 446.7,80.9 450.8,80.9 450.8,80.9 454.9,80.9 454.9,80.9 459.0,80.9 459.0,80.9 463.1,80.9 463.1,80.9 467.2,80.9 467.2,80.9 475.4,80.9 475.4,82.5 479.6,82.5 479.6,82.5 487.8,82.5 487.8,65.0 491.9,65.0 491.9,66.6 496.0,66.6 496.0,66.6 500.1,66.6 500.1,66.6 504.2,66.6 504.2,65.0 508.3,65.0 508.3,65.0 512.4,65.0 512.4,65.0 516.5,65.0 516.5,73.0 520.6,73.0 520.6,73.0 524.8,73.0 524.8,73.0 528.9,73.0 528.9,73.0 533.0,73.0 533.0,73.0 537.1,73.0 537.1,73.0 541.2,73.0 541.2,73.0 545.3,73.0 545.3,73.0 549.4,73.0 549.4,73.0 553.5,73.0 553.5,73.0 561.8,73.0 561.8,73.0 565.9,73.0 565.9,73.0 570.0,73.0 570.0,73.0 574.1,73.0 574.1,73.0 578.2,73.0 578.2,73.0 582.3,73.0 582.3,73.0 586.4,73.0 586.4,73.0 590.5,73.0 590.5,73.0 594.6,73.0 594.6,73.0 598.7,73.0 598.7,73.0 602.9,73.0 602.9,73.0 607.0,73.0 607.0,73.0 611.1,73.0 611.1,73.0 615.2,73.0 615.2,73.0 623.4,73.0 623.4,73.0 627.5,73.0 627.5,229.9 631.6,229.9 631.6,229.9 635.7,229.9 635.7,229.9 639.8,229.9 639.8,233.1 643.9,233.1 643.9,233.1 652.2,233.1 652.2,233.1 656.3,233.1 656.3,233.1 660.4,233.1 660.4,233.1 664.5,233.1 664.5,233.1 668.6,233.1 668.6,233.1 672.7,233.1 672.7,233.1 676.8,233.1 676.8,233.1 680.9,233.1 680.9,233.1 685.1,233.1 685.1,233.1 689.2,233.1 689.2,233.1 693.3,233.1 693.3,233.1 697.4,233.1 697.4,233.1 701.5,233.1 701.5,233.1 705.6,233.1 705.6,231.5 709.7,231.5 709.7,231.5 713.8,231.5 713.8,228.4 717.9,228.4 717.9,226.8 722.0,226.8 722.0,226.8 730.3,226.8 730.3,226.8 738.5,226.8 738.5,209.3 742.6,209.3 742.6,209.3 746.7,209.3 746.7,209.3 750.8,209.3 750.8,209.3 754.9,209.3 754.9,204.6 759.0,204.6 759.0,204.6 767.2,204.6 767.2,204.6 771.4,204.6 771.4,207.7 779.6,207.7 779.6,207.7 783.7,207.7 783.7,207.7 787.8,207.7 787.8,207.7 791.9,207.7 791.9,207.7 796.0,207.7 796.0,207.7 800.1,207.7 800.1,207.7 804.2,207.7 804.2,207.7 808.4,207.7 808.4,207.7 812.5,207.7 812.5,207.7 820.7,207.7 820.7,207.7 837.1,207.7 837.1,207.7 841.2,207.7 841.2,207.7 845.3,207.7 845.3,207.7 849.4,207.7 849.4,207.7 853.6,207.7 853.6,207.7 857.7,207.7 857.7,207.7 861.8,207.7 861.8,207.7 865.9,207.7 865.9,207.7 870.0,207.7" fill="none" stroke="var(--theme-color,#7c3aed)" stroke-width="2" stroke-linejoin="round"/>
<circle cx="48.0" cy="236.3" r="4" fill="var(--theme-color,#7c3aed)"/>
<text x="57.0" y="227.3" font-size="12.5" fill="var(--base-color,#282a36)" text-anchor="start">20, and all of them reads</text>
<circle cx="487.8" cy="65.0" r="4" fill="var(--theme-color,#7c3aed)"/>
<text x="487.8" y="53.0" font-size="12.5" fill="var(--base-color,#282a36)" text-anchor="middle">128</text>
<circle cx="865.9" cy="207.7" r="4" fill="var(--theme-color,#7c3aed)"/>
<text x="859.9" y="195.7" font-size="12.5" fill="var(--base-color,#282a36)" text-anchor="end">38 today</text>
<text x="48" y="318" font-size="12" fill="var(--muted-color,#5a6896)">y axis: commands allowed to run without asking</text>
</svg>

The shape to take from it is that it moved in both directions and nothing broke.
Token scopes moved more than once too, in the same unhurried way. Start wherever
you are comfortable and adjust when you feel like it.

| Instead of | You can |
|---|---|
| a broad `git` grant, so commits are not interrupted | allow nothing, and let `/anchor:commit` show you the diff and the message first |
| a broad `gh` or `glab` grant, so change requests can be opened | allow nothing, and let `/anchor:prepare-review` draft the description for you to approve |
| widening because the prompts are wearing you down | allow the specific skills you have come to trust, rather than the commands underneath them |


## What you do not have to decide yet

New tools usually open with a configuration page. There is
[one](/guides/configuring) for when you want it. You do not need it before your
first commit.

- **No diff viewer?** A review with nothing installed to run it comes back
  *ungraded*, and `anchor` walks the change with you in chat. It does not ask
  *"you saw the diff, approve?"*, which would turn a missing tool into your
  sign-off.
- **No editor set?** It uses `core.editor` and git's own chain, the same editor
  `git commit` would have opened.
- **Nothing lands in your repo.** Every knob is a `git config anchor.*` value in
  `.git/config`, which is never tracked. `anchor` adds no file to your project.

## Make a change

That is the whole setup. Edit some code, then:

```text
/anchor:commit
```

It reviews the pending changeset with you, writes a *why*-first message, and
commits and pushes once the review is clean. Then, on the pushed branch:

```text
/anchor:prepare-review
```

It rebases on the default branch, drafts the description a reviewer needs, and
opens the change request as a draft.

`commit` works with no forge CLI at all. The skills that touch a change request,
issue, pipeline, or release need the one for your `origin` remote:
[`gh`](https://cli.github.com) for GitHub,
[`glab`](https://gitlab.com/gitlab-org/cli#installation) for GitLab.

What each skill does, step by step, is in the sidebar. The invariants behind the
prompts are on [Home](/#tenets).
