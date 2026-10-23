# What a review tool can show

anchor writes markdown that a reviewer reads inside a review tool, not on a
forge: the `(context).md` file revdiff opens beside a diff, the size stack
(`scripts/lib/size-stack.sh`), the reply table, and the context an editor review
carries under its scissors line. Neither tool renders that markdown. Each one
highlights its *source*, so what stands out is whatever the tool's lexer gives a
colour, and that differs between tools.

Reach for this guide when a line has to stand out, or recede, in one of those
files. Prefer a construct both tools style (*Across both*, below); use a
tool-specific one only in a file that tool alone opens.

## The palette

Observed in revdiff `v1.13.0` and helix `25.07.1`, both on their `dracula`
theme: `theme = dracula` in `~/.config/revdiff/config` (the theme sets the
chroma style too, and `chroma-style` overrides it) and in
`~/.config/helix/config.toml`. The colours come from the theme, so read a colour
below as the role the theme gives it, not a fixed value.

| Construct | Source | revdiff | helix |
| --- | --- | --- | --- |
| Heading | `## text` | bold | purple, bold |
| Inline code | `` `text` `` | yellow | plain |
| Bold | `**text**` | plain, asterisks shown | orange, bold |
| Italic | `*text*` | not measured | yellow, italic, per the theme file |
| Blockquote | `> text` | marker coloured, text plain | marker coloured, text italic |
| Bare fence | ` ``` ` | fence lines yellow, content plain | content plain |
| Diff fence, `+` line | ` ```diff ` | green, bold | green |
| Diff fence, `-` line | ` ```diff ` | red | red |
| Diff fence, `@@` line | ` ```diff ` | bold | plain |
| Diff fence, `!` line | ` ```diff ` | plain | plain |
| Diff fence, context line | ` ```diff `, leading space | plain | plain |
| Emoji | `⚠️` | shown, two cells wide | shown |

A fence colours its content only when it names a language: both tools hand a
fenced block to that language's highlighter (chroma's lexer in revdiff, a
tree-sitter injection in helix). A bare fence changes nothing about the lines
inside it.

### Across both

Headings and the `+` / `-` lines of a ` ```diff ` fence are the only constructs
both tools style, and only the `+` / `-` lines get the same colour in each. A
`+` or `-` line carries the diff's meaning (added, removed) wherever it appears,
so it fits content that *is* an addition or a removal, like the size stack's
bars, and misleads anywhere else.

## Making a line stand out

- **In a file revdiff alone opens** (`(context).md`): put the whole line in
  inline code. It turns yellow without fence lines around it, and borrows no
  meaning from a diff. The line can't itself contain a backtick.
- **In an editor review's context**: emphasis is mostly moot. A commit message's
  context sits below git's scissors line, which helix's commit mode greys, and
  every other artifact carries its context inside an HTML comment, where nothing
  is highlighted.

## Making a line recede

Plain text draws in the theme's foreground colour, which is the brightest text
on the screen. For a sentence, dropping the colour is enough to set it back. A
glyph that fills its cell is different: an uncoloured solid block (`█`) is as
heavy as a coloured one beside it, and outshines it. A glyph with less ink
recedes instead: the size stack draws its earlier passes in the light shade
`░`, at the cost of the eighth-cell steps the solid blocks draw. The dark shade
`▓` reads almost as solid, and line glyphs (`─`, `━`, `▁`) stop reading as
bars.

## Layout

- **Box drawing** (`┌─┐`, `╭─╮`) renders in revdiff as plain text, with no
  fence around it (helix not measured). The line a reviewer acts on, such as
  quitting to approve, is outlined this way (`scripts/lib/callout.sh`). Its right edge stays straight only when every line
  holds the same number of terminal cells, and an emoji is two cells wide while
  counting as one character, so a box around an emoji line comes out ragged.
- **A single newline** joins two lines in any markdown renderer. These tools
  show the source, so it doesn't here, but a file a forge will also render needs
  the blank line or a fence.
