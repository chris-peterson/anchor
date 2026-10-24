#!/usr/bin/env bash
# How big a change is and how big each pass over it was, drawn as bars a
# reviewer compares at a glance. A percent per pass has to be read and held in
# the head; bars against the same scale show which pass was large and whether
# they are shrinking.
#
# Sourced, not executed.
#
#   anchor_size_stack [current] < <rows>
#
# Each row is `label<TAB>files<TAB>added<TAB>removed`, in the order drawn, and
# an empty label draws the counts alone. The output is a ```diff fence, since a
# markdown viewer hands fenced code to the language it names and the diff lexer
# colours a `+` line as an insertion and a `-` line as a deletion
# (guides/review-palette.md). A row's heading is a context line, so no label
# reads as a diff construct. Every bar is scaled against the largest count in
# the stack, and how long that bar is follows how big the largest pass is: a
# third of the width up to 100 lines, two thirds under 1000, the full width
# beyond. A full-width bar for a one-line change reads as a big one; the scale
# is taken from the stack as drawn, so each round rebalances.
#
# `current` marks the first row as the pass under review. The rows after it are
# history, drawn as context lines the lexer leaves uncoloured, each count signed,
# so colour lands on the pass being reviewed. Their bars are drawn in the light shade `░`: an uncoloured solid
# block takes the theme's brightest colour and outshines the coloured bars above
# it. The shade has no eighth-cell steps, so those bars round to whole cells.

ANCHOR_SIZE_STACK_WIDTH=30

anchor_size_stack() {
  # shellcheck disable=SC2016
  printf '```diff\n'
  awk -F '\t' -v FULL="$ANCHOR_SIZE_STACK_WIDTH" -v CURRENT="$([[ "${1:-}" == current ]] && echo 1)" '
    function bar(v,   cells, full, eighths, s, i) {
      cells = v * W / max; full = int(cells); eighths = int((cells - full) * 8)
      s = ""
      for (i = 0; i < full; i++) s = s "█"
      if (eighths > 0) s = s part[eighths]
      return (s == "" ? part[1] : s)
    }
    function shade(v,   cells, s, i) {
      cells = int(v * W / max + 0.5); if (cells < 1) cells = 1
      s = ""
      for (i = 0; i < cells; i++) s = s "░"
      return s
    }
    BEGIN { split("▏ ▎ ▍ ▌ ▋ ▊ ▉", part, " ") }
    NF >= 4 { n++; label[n] = $1; files[n] = $2; add[n] = $3 + 0; del[n] = $4 + 0
              if (add[n] > max) max = add[n]; if (del[n] > max) max = del[n]
              if (add[n] + del[n] > big) big = add[n] + del[n] }
    END {
      W = (big <= 100 ? int(FULL / 3) : big < 1000 ? int(FULL * 2 / 3) : FULL)
      for (i = 1; i <= n; i++) {
        muted = CURRENT && i > 1
        head = (add[i] == 0 && del[i] == 0) ? "no changes" \
          : sprintf("%d file%s", files[i], (files[i] == 1 ? "" : "s"))
        if (label[i] != "") head = label[i] " · " head
        printf " %s\n", head
        if (muted) {
          if (add[i] > 0) printf " %s +%d\n", shade(add[i]), add[i]
          if (del[i] > 0) printf " %s -%d\n", shade(del[i]), del[i]
        } else {
          if (add[i] > 0) printf "+%s %d\n", bar(add[i]), add[i]
          if (del[i] > 0) printf "-%s %d\n", bar(del[i]), del[i]
        }
      }
    }'
  # shellcheck disable=SC2016
  printf '```\n'
}

# One stack row from a `git diff --numstat` read on stdin: the files it names
# and the lines it adds and removes, a binary file counting as a file with no
# lines.
anchor_size_row() {
  awk -F '\t' -v L="$1" '{ f++; a += $1; d += $2 } END { printf "%s\t%d\t%d\t%d\n", L, f, a, d }'
}
