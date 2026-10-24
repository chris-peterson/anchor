#!/usr/bin/env bash
# The line a reviewer acts on (quit to approve, save to approve), outlined so it
# stands out from the prose around it in a file the review tool shows as source.
#
# Sourced, not executed.
#
#   anchor_box [--light] <text>   the text wrapped and outlined; --light draws
#                                 it dashed, for text the reader may skip
#
# A blank line in <text> separates paragraphs, and a tab splits a row, its
# right part set against the box's right edge. Inline code is never split
# across rows, since a span broken by the wrap loses its highlighting. The right
# edge stays straight only when every character is one terminal cell wide
# (guides/review-palette.md), so the text holds no emoji.

ANCHOR_CALLOUT_WIDTH=72

anchor_box() {
  local para word line rule="" w=0 i h='─' v='│' tl='╭' tr='╮' bl='╰' br='╯'
  local -a words box_rows=()
  if [[ "${1:-}" == --light ]]; then
    h='┄' v='┆' tl='┌' tr='┐' bl='└' br='┘'
    shift
  fi
  while IFS= read -r para; do
    para=$(awk '{ o = ""; c = 0
      for (i = 1; i <= length($0); i++) { ch = substr($0, i, 1)
        if (ch == "`") c = !c; else if (c && ch == " ") ch = "\037"; else if (ch == "\t") ch = "\036"
        o = o ch }
      print o }' <<<"$para")
    read -ra words <<<"$para"
    if [[ ${#words[@]} == 0 ]]; then box_rows+=(""); continue; fi
    line=""
    for word in "${words[@]}"; do
      if [[ -n "$line" && $(( ${#line} + 1 + ${#word} )) -gt $ANCHOR_CALLOUT_WIDTH ]]; then
        box_rows+=("$line"); line="$word"
      else
        line="${line:+$line }$word"
      fi
    done
    box_rows+=("$line")
  done <<<"$1"
  for line in "${box_rows[@]}"; do (( ${#line} > w )) && w=${#line}; done
  for (( i = 0; i < w + 2; i++ )); do rule+="$h"; done
  printf '%s%s%s\n' "$tl" "$rule" "$tr"
  for line in "${box_rows[@]}"; do
    if [[ "$line" == *$'\x1e'* ]]; then
      printf '%s %s%*s%s %s\n' "$v" "${line%%$'\x1e'*}" $(( w - ${#line} + 1 )) "" "${line#*$'\x1e'}" "$v"
    else
      printf '%s %s%*s %s\n' "$v" "$line" $(( w - ${#line} )) "" "$v"
    fi | sed $'s/\x1f/ /g'
  done
  printf '%s%s%s\n' "$bl" "$rule" "$br"
}
