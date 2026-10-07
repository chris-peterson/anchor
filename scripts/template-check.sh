#!/usr/bin/env bash
# List what a description composed into a team template still owes before it
# ships: the template's own placeholders that survived into the draft, and every
# checkbox, each of which is a claim the drafter has to settle against evidence.
#
# A placeholder is found in the template first, then looked for in the draft:
#
#   TODO  TBD  FIXME  XXX        a template line carrying one, as a whole
#                                uppercase word, that reappears verbatim
#   <!-- … -->                   an HTML comment the template opens
#   < Type your summary here >   an angle-bracket prompt: anything in <…> that
#                                isn't an HTML tag or a URL
#
# Matching against the template is what keeps the drafter's own text out of the
# report: a description can carry an HTML comment, a `<T>` generic, or the word
# TODO in prose, and none of them came from the template. Fenced code blocks and
# inline code spans are skipped on both sides.
#
# Checkboxes are reported with the state the draft gives them. The script can't
# say whether a box is right, and doesn't try: the state in a template or a
# prior description is the claim under test, not evidence for it.
#
# Output, one line per finding, then the counts:
#
#   PLACEHOLDER <line> <token>: <line text>
#   CHECKBOX <line> <checked|unchecked>: <item text>
#   PLACEHOLDERS=<n>
#   CHECKBOXES=<n>
#
# Usage:
#   template-check.sh --template <template.md> <draft.md>
#
# Exit codes:
#   0   no placeholders (checkboxes may still be listed)
#   1   at least one placeholder
#   64  usage error
#   66  the template or the draft is unreadable

set -euo pipefail

usage() { echo "usage: template-check.sh --template <template.md> <draft.md>" >&2; exit 64; }

template=""
draft=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template="${2:-}"; [[ -n "$template" ]] || usage; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$draft" ]] || usage; draft="$1"; shift ;;
  esac
done
[[ -n "$template" && -n "$draft" ]] || usage
for f in "$template" "$draft"; do
  [[ -r "$f" && -f "$f" ]] || { echo "template-check.sh: cannot read $f" >&2; exit 66; }
done

awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function is_html_tag(t,    name) {
  name = t
  sub(/^\//, "", name)
  sub(/[ \t\/].*$/, "", name)
  name = tolower(name)
  return name ~ /^(a|b|i|p|br|hr|em|strong|code|pre|kbd|sub|sup|del|ins|div|span|img|picture|source|video|details|summary|table|thead|tbody|tr|td|th|ul|ol|li|blockquote|h[1-6])$/
}

# Sets `scan` to the line with code spans removed, and returns 0 for a line to
# skip: a fence, a line inside one, or the tail of a multi-line HTML comment.
function skip_line(line,    rest) {
  if (FNR == 1) { fence = ""; in_comment = 0 }
  if (fence != "") {
    if (line ~ ("^[ \t]*" fence)) fence = ""
    return 1
  }
  if (line ~ /^[ \t]*```/) { fence = "```"; return 1 }
  if (line ~ /^[ \t]*~~~/) { fence = "~~~"; return 1 }
  if (in_comment) {
    if (index(line, "-->")) in_comment = 0
    return 1
  }
  scan = line
  gsub(/`[^`]*`/, "", scan)
  return 0
}

function report(token, text,    key) {
  key = FNR SUBSEP token
  if (key in reported) return
  reported[key] = 1
  printf "PLACEHOLDER %d %s: %s\n", FNR, token, trim(text)
  placeholders++
}

BEGIN { placeholders = 0; checkboxes = 0; nwords = split("TODO TBD FIXME XXX", words, " ") }

# The template: collect what its placeholders look like.
FNR == NR {
  if (skip_line($0)) next
  if (index(scan, "<!--")) {
    opener = trim(substr(scan, index(scan, "<!--")))
    sub_needle[opener] = "<!--"
    if (!index(substr(scan, index(scan, "<!--") + 4), "-->")) in_comment = 1
    next
  }
  for (w = 1; w <= nwords; w++) {
    if (scan ~ ("(^|[^A-Za-z0-9_])" words[w] "([^A-Za-z0-9_]|$)")) {
      line_needle[trim($0)] = words[w]
    }
  }
  rest = scan
  while (match(rest, /<[^<>]+>/)) {
    inner = substr(rest, RSTART + 1, RLENGTH - 2)
    rest = substr(rest, RSTART + RLENGTH)
    if (is_html_tag(inner)) continue
    if (inner ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) continue
    sub_needle["<" inner ">"] = "<" inner ">"
  }
  next
}

# The draft: report what it carried over, and list every checkbox.
{
  if (skip_line($0)) next
  t = trim($0)
  if (t in line_needle) report(line_needle[t], $0)
  for (needle in sub_needle) {
    if (index(scan, needle)) report(sub_needle[needle], $0)
  }
  if (index(scan, "<!--") && !index(substr(scan, index(scan, "<!--") + 4), "-->")) in_comment = 1

  if (match($0, /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+\[[ xX]\]/)) {
    box = substr($0, RSTART + RLENGTH - 2, 1)
    item = trim(substr($0, RSTART + RLENGTH))
    printf "CHECKBOX %d %s: %s\n", FNR, (box == " " ? "unchecked" : "checked"), item
    checkboxes++
  }
}

END {
  printf "PLACEHOLDERS=%d\n", placeholders
  printf "CHECKBOXES=%d\n", checkboxes
  exit (placeholders > 0 ? 1 : 0)
}
' "$template" "$draft"
