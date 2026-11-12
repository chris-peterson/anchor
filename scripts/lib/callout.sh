#!/usr/bin/env bash
# The line a reviewer acts on (quit to approve, save to approve), outlined so it
# stands out from the prose around it in a file the review tool shows as source.
#
# Sourced, not executed.
#
#   anchor_box <text> [<title>]
#                       the text wrapped and outlined, <title> set into the
#                       top edge
#
# A blank line in <text> separates paragraphs, and a tab splits a row, its
# right part set against the box's right edge. A line opening with `- ` is a
# list item, its wrapped rows indented under its text. Inline code is never split
# across rows, since a span broken by the wrap loses its highlighting. The right
# edge stays straight only when every character is one terminal cell wide
# (guides/review-palette.md), so the text holds no emoji. The outline is the
# solid set, which every terminal draws joined.

ANCHOR_CALLOUT_WIDTH=72

# Sets _cols to the columns $1 takes: its characters, counted in any locale by
# dropping UTF-8 continuation bytes, since `${#s}` counts bytes under C.
anchor_box_cols() {
  local LC_ALL=C s="$1"
  s=${s//[$'\x80'-$'\xbf']/}
  _cols=${#s}
}

anchor_box() {
  local para word line indent top rule="" w=0 i lw ww h='─' v='│' tl='╭' tr='╮' bl='╰' br='╯' _cols
  local -a words box_rows=()
  while IFS= read -r para; do
    para=$(awk '{ o = ""; c = 0
      for (i = 1; i <= length($0); i++) { ch = substr($0, i, 1)
        if (ch == "`") c = !c; else if (c && ch == " ") ch = "\037"; else if (ch == "\t") ch = "\036"
        o = o ch }
      print o }' <<<"$para")
    read -ra words <<<"$para"
    if [[ ${#words[@]} == 0 ]]; then box_rows+=(""); continue; fi
    line="" indent=""
    [[ "${words[0]}" != - ]] || indent="  "
    for word in "${words[@]}"; do
      anchor_box_cols "$line"; lw=$_cols
      anchor_box_cols "$word"; ww=$_cols
      if [[ -n "$line" && $(( lw + 1 + ww )) -gt $ANCHOR_CALLOUT_WIDTH ]]; then
        box_rows+=("$line"); line="$indent$word"
      else
        line="${line:+$line }$word"
      fi
    done
    box_rows+=("$line")
  done <<<"$1"
  for line in "${box_rows[@]}"; do anchor_box_cols "$line"; (( _cols > w )) && w=$_cols; done
  top="${2:+$h $2 }"
  anchor_box_cols "$top"
  (( _cols + 1 > w + 2 )) && w=$(( _cols - 1 ))
  for (( i = 0; i < w + 2; i++ )); do rule+="$h"; done
  for (( i = _cols; i < w + 2; i++ )); do top+="$h"; done
  printf '%s%s%s\n' "$tl" "$top" "$tr"
  for line in "${box_rows[@]}"; do
    anchor_box_cols "$line"
    if [[ "$line" == *$'\x1e'* ]]; then
      printf '%s %s%*s%s %s\n' "$v" "${line%%$'\x1e'*}" $(( w - _cols + 1 )) "" "${line#*$'\x1e'}" "$v"
    else
      printf '%s %s%*s %s\n' "$v" "$line" $(( w - _cols )) "" "$v"
    fi | sed $'s/\x1f/ /g'
  done
  printf '%s%s%s\n' "$bl" "$rule" "$br"
}
