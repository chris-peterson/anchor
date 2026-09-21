# Read instructions at the phase that needs them

Each skill's `SKILL.md` is the workflow entry point. Its linked phase files
contain the full operating instructions. Read every file required for the
current phase before performing that phase's actions. Read conditional phases
only when their condition applies; never load every skill's references upfront.
The entry point's summaries do not replace those reads.

Resolve `references/foo.md` links relative to the entry point's directory, so
the installed path is `<anchor-root>/skills/<name>/references/foo.md`. Shared
`<anchor-root>` paths still resolve from the plugin root. Site-style links in
shared documents, such as `/guides/cr-verbosity`, name the bundled
`guides/cr-verbosity.md`, not a filesystem-root path or a reason to browse.

## Complete reads without truncated output

Read each phase separately using the host's file-reading tools. Do not combine
all phase files into one tool response. Phase files are at most 8,000 UTF-8
bytes, but the host may impose a smaller output limit: if it reports truncated
output, read the missing ranges before acting. Never use `head`, `tail`, search
snippets, or a clipped tool response as a substitute for required instructions.

For a large shared guide, first inspect its headings and locate the section
needed for the current decision. Then read that entire section, including its
subsections, in bounded line ranges. For example, `rg -n '^#{1,4} ' <path>`
locates headings and `sed -n '40,100p' <path>` reads a range. Choose ranges to
fit the tool's output budget; an arbitrary line count is not a byte guarantee.
Repeat until the section is complete. Account for headings inside fenced
examples when identifying section boundaries.

If a reference is missing or unreadable, report the concrete problem and stop
the dependent action. After compaction or resuming a workflow, recover the
resolved target, phase, helper results, reviewed artifact, and approval state;
re-read the current phase rather than guessing its remaining instructions.

## Which parts of the shared guides to read

| Shared resource | Read when |
|---|---|
| `guides/forge-cookbook.md` | Read the named operation's section and its applicable targeting/defaults prerequisites before constructing that operation. Use the selected forge's command; retain both forge implementations in the guide. |
| `guides/configuring.md` | Read Defaults and the entries for keys returned by the current helper or used by the current phase. Read the relevant In depth section only when applying that behavior, such as review configuration or pipeline watching. |
| `guides/cr-verbosity.md` | Read the introductory rules, “Verbosity abbreviates; it never removes a section”, and budget interaction when calibrating CR prose. Read the example closest to the selected setting if needed; the five examples are alternatives, not five required drafts. |
| `guides/cr-formatting.md` | Read the visualization menu, prose conventions, and deep-link rules when drafting a CR. Read collapsible sections, Mermaid, and screenshot instructions when the artifact uses those features. |
| `guides/release-models.md` | Read the introduction and the complete section for the model selected by recon and the repo's publishing instructions. Other models are alternatives. |
| `templates/cr-description.md` | Read the introduction and every section's inclusion criteria. Read full instructions for each applicable section, including the project-template composition rules. Do not skip a required section because verbosity is low. |

These are reading boundaries, not exceptions to the guides. Preserve all
applicable requirements. Read any other guide or template a phase requires in
full unless that phase explicitly names a section; use multiple bounded reads
when necessary. Keep helper output separate from instruction reads so neither
gets lost in a combined response's output limit.
