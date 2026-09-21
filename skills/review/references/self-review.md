## Step 5: Self-review — the CR is yours

Reached when Step 1 reported `IS_OWN_CR=1`. Nothing in this step posts to the
forge: a thread an author opens against themselves is a round trip with no
reviewer in it, so the findings are a fix list instead. Steps 6 and 7 don't run.

1. **Give them the fix list.** The `--preview` render is it — put it in your
   reply as Step 4 says. Ask which findings they want acted on; a finding they
   disagree with is dropped, not argued.
2. **Fix in the working tree**, one finding at a time, running the project's
   tests as you go. Commits go through `anchor:commit`, which decides
   amend-vs-new-commit from the push state and the draft flag — don't rewrite
   history here by hand.
3. **Re-review the corrected diff.** Re-run Step 1 so `CR_HEAD_SHA` and
   `DIFF_RANGE` cover the fix commits, then Steps 3 and 4 against the new head.
   That is a loop inside this invocation, not a reason to start over: repeat
   until a pass comes back with nothing the user wants fixed.
4. **Hand it off.** Ask with structured choices when the host supports that
   (header `Handoff`), or directly otherwise:

   - **Mark ready and request reviewers** — ask who, then do both.
   - **Mark ready** — ready with no reviewer named.
   - **Leave it a draft** *(default)* — a finished outcome. The author reviewed
     their own change and isn't handing it over yet; say so and stop.
   - **Post findings as threads** — for a known gap or a follow-up the author
     wants a reviewer to see. Those findings go out through Steps 6 and 7 with
     the same gates as anyone else's CR.

   Neither marking ready nor requesting a reviewer happens without the user
   picking it here. `anchor:merge` also offers to mark a CR ready, but it asks
   as a gate on the merge — the author is already landing the change by then, so
   the question arrives long after the moment they wanted to hand it over.

   Clearing the flag goes through the helper, which reads it fresh, covers both
   forges, and announces `cr.ready` so a sibling tracking deliverables sees the
   CR leave draft:

   ```bash
   bash "<anchor-root>/scripts/mark-ready.sh" --forge <FORGE> --cr <CR_IID>
   ```

   `ALREADY_READY=1` means someone got there first; say that rather than
   reporting a change you didn't make. Requesting reviewers is a separate call,
   and its invocation for both forges is in
   `<anchor-root>/guides/forge-cookbook.md`.

Then report as Step 8 describes.
