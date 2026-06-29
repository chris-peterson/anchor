# Markdown gotchas

Markdown that looks right in the source can render wrong — and the source
gives no hint, so the mistake surfaces only once a renderer (GitHub, GitLab,
the docs site) has its way with it. These are the recurring traps when
authoring any rendered markdown: CR/issue bodies, review comments, and the
guides on this site. anchor's skills consult this guide whenever they emit
markdown a renderer will display.

The fixes share a theme: a literal character that the renderer would read as
formatting is neutralized by a backtick code span (which renders verbatim) or
a leading backslash escape. Inside fenced code blocks and inline backticks,
none of these characters are special — the traps below are all about
*unfenced prose*.

## Characters that trigger unintended formatting

Four characters turn into formatting when they appear in matched pairs in
prose. The danger is two unrelated uses in the same paragraph pairing up:

| Character | Renders as | Trap |
| --- | --- | --- |
| `~` | strikethrough | GFM strikes text wrapped in one *or* two tildes, so two approximate values pair up: `~200ms` startup and `~500ms` teardown strikes through "startup and". |
| `$` | inline math | GitHub and GitLab read `$...$` as KaTeX and swallow what's between — two shell variables in one paragraph (`$FAMILY`, `$REGION`) render as a blank gap. |
| `_` | italics | `_id` and `name_` in the same line italicize everything between. |
| `*` | bold/italic | `*` inside a flag name or a `2 * n` expression pairs with the next `*`. |

Fix: backtick the token (`` `~200ms` ``, `` `$FAMILY` ``) or escape the sign
(`\~200ms`, `\$FAMILY`). Backticking is usually better — it also marks the
token as code for a reader scanning the prose.

## Nested code fences need a longer outer fence

A fenced block closes at the first fence with *at least as many* backticks. So
a three-backtick wrapper around content that itself contains three-backtick
blocks (mermaid, code samples, an inline ` ```text ` fence) closes early, and
everything after the inner fence renders as raw text.

Use a four-backtick outer fence whenever the inner content has any
three-backtick fences:

`````text
````markdown
```mermaid
graph TD; A --> B
```
````
`````

## Mermaid blocks

- **The `%%{ init }%%` directive is the first line *inside* the fence, not
  before it.** A bare `%%{ init }%%` line above the ` ```mermaid ` opener
  renders as raw text and the diagram loses its theme. Order: ` ```mermaid `
  → `%%{ init: { 'look': 'handDrawn' } }%%` → diagram → closing fence.
- **Every mermaid block needs its closing fence.** Easy to drop when the
  diagram is the last thing before a section break, which then swallows the
  following prose into the block.

## Collapsible `<details>` blocks need blank lines

Markdown inside a `<details>`/`<summary>` wrapper renders only with a blank
line after `</summary>` and before `</details>`. Without them, tables, code
fences, and lists inside show as raw text.

```text
<details>
<summary>Title</summary>

| col | col |
| --- | --- |

</details>
```

## Tables can't be indented under a list item

A table indented beneath a list item renders unreliably in GFM. Keep tables
at the root level — break them out of the surrounding list rather than nesting
them under a bullet.
