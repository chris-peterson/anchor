## Step 4: Review the drafted description

Write the drafted description to `DESC_DRAFT_PATH` from Step 1's block — the review below reads it, and the path is already `mktemp`'d, so this costs no `mktemp` call of your own.

**The user reads the description in the review tool, not in chat.** Same discipline as `anchor:commit`, which reviews the drafted commit message alongside the diff it describes rather than gating on it in chat: you don't ask someone to approve prose they haven't read. The review *is* the presentation, so it comes **before** any write prompt — never after.

### Output checklist (walk this before the review opens)

The description gets pasted into a markdown renderer, so rendering bugs are user-visible — and the review shows the source, not the render, so a broken fence survives a clean verdict. Walk the general rendering gotchas in the bundled `<anchor-root>/guides/markdown-gotchas.md` — character escaping (`~`/`$`/`_`/`*`), nested code fences, mermaid blocks, collapsible `<details>`, tables in lists — then these CR-description-specific checks:

- **Backtick coverage is generous — except for forge-autolink tokens.** Re-scan the description for grep-bait: env vars (`$FAMILY`, `$CI_PIPELINE_CREATED_AT`), config keywords (`extends:`, `needs:`, `on_success`, `manual`, `allow_failure`), job/product/feature suffixes that match identifiers in the diff, CLI flags, file paths. The "if a reader might paste it into a terminal" test is more permissive than "code identifier only" — err generous. **But** scan separately for CR/issue refs (`!148`, `#42`), commit SHAs, and user @mentions — these must be **bare text** to autolink; backticks render them as inert code spans.
- **Inline single quotes around `'all'` / `'true'` style values** read fine in prose but lose their distinguishing weight in scan-mode. Convert literal dropdown/enum values to backticks.
- **Every deep link is an `anchor:` placeholder** — no line numbers, no hand-built anchors (Step 3).
- **Resolve the placeholders before the review opens.** Every token has to name exactly one changed line, and that is checkable without a CR:

  ```bash
  bash "<anchor-root>/scripts/deep-links.sh" --check <DESC_DRAFT_PATH> \
    --base <DEFAULT_BRANCH>
  ```

  It exits non-zero with one `UNRESOLVED <kind> <path> <token>` per problem, and each kind is an authoring fix: `ambiguous` (several changed lines match — the candidates are listed with their content, so copy a longer substring off the one you meant), `unchanged` (in the file but not on a changed line), `absent` (a typo), `unknown-file` (a path the range doesn't touch), `malformed` (an `anchor:` that isn't a link destination). Fix and re-run until it's clean — a placeholder that survives into Step 4's expansion stalls the write on a CR that already exists. It needs the clean tree Step 1's `STATE=match` already established: line content comes from the working tree and changed hunks from `<DEFAULT_BRANCH>...HEAD`, and it emits `DEEP_LINK_TREE=dirty` when those have diverged. Skip it on the `skip-deep-links` path, where the description carries no links at all.
- **A description that predates this convention needs the backstop instead.** Re-running against a CR whose description came from elsewhere means hand-built anchors with hand-read line numbers, which `--check` doesn't see. Run `--verify <DESC_DRAFT_PATH> --forge <FORGE> --cr-url <CR_URL> --base <DEFAULT_BRANCH>` over those, and re-point each `SUSPECT`: `out-of-range`, `blank-line`, `unchanged-line`, `unknown-file`, `malformed` (a line part in a shape the forge won't resolve). A link that landed on the *wrong changed line* is the one case it can't see — which is what replacing it with a placeholder fixes.
