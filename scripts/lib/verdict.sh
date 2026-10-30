#!/usr/bin/env bash
# The Review box of a revdiff review's (context).md: the keys that work the
# review, then the choices that end it. revdiff quits one way and exits the same
# for "nothing to say" as for "discarded what I said", so the choice has to be
# written down, and a quit that writes none is asked about rather than read.
#
# Sourced only; the caller sources lib/callout.sh and lib/hints.sh first.
#
#   anchor_review_box [--answer <text>] <bin> <approve> <reject> [<editor>]
#                         the box, naming what each choice leads to; with
#                         <editor>, a third choice relaunches the review there.
#                         With hints on, <bin>'s keys and how to choose come
#                         with the choices, and the box closes on how to hide
#                         them; with hints off it holds the choices alone.
#                         --answer is how to answer a review of items (a batch,
#                         a round), in place of what other notes do
#   anchor_verdict_lines <file>
#                         where the choices sit in <file>, as `accept\t<n>`,
#                         `reject\t<n>`, and `relaunch\t<n>`, one line for each
#                         row a choice wraps onto; nothing for a file without
#                         the box

ANCHOR_REVIEW_BOX_TITLE="Review"

# A note on a choice's line chooses it too, which is how an approval carries
# other notes as comments; the box names the simpler way.
# shellcheck disable=SC2016
anchor_review_box() {
  local choices keys answer="" others='Notes of any other kind go back for a revision you review again.'
  if [[ "${1:-}" == --answer ]]; then answer=$2 others=""; shift 2; fi
  choices=$(printf '%s\n' "- \`approve\`: $2" "- \`reject\`: $3" \
    ${4:+"- **Relaunch in $4**: leave a note on this line to quit revdiff and start this review over in $4, where what you save is the draft"})
  if ! anchor_hints_on diff; then
    anchor_box "$choices" "$ANCHOR_REVIEW_BOX_TITLE"
    return
  fi
  keys=$(anchor_revdiff_hints "$1")
  anchor_box "$(printf '%s\n' \
    ${keys:+"$keys"} ${keys:+''} \
    ${answer:+"$answer"} ${answer:+''} \
    'When you are done, leave a single note here saying `approve` or `reject`, then quit with `q`:' \
    "$choices" \
    '' \
    ${others:+"$others"} ${others:+''} \
    '*Tell the agent "hide hints" to shrink this box to the choices.*')" \
    "$ANCHOR_REVIEW_BOX_TITLE"
}

anchor_verdict_lines() {
  [[ -f "$1" ]] || return 0
  awk -v top="╭─ $ANCHOR_REVIEW_BOX_TITLE " '
    index($0, top) == 1 { on = 1; next }
    on && /^╰/ { exit }
    on {
      row = $0; sub(/^│ /, "", row)
      if (index(row, "- `approve`:") == 1) choice = "accept"
      else if (index(row, "- `reject`:") == 1) choice = "reject"
      else if (index(row, "- **Relaunch in ") == 1) choice = "relaunch"
      else if (substr(row, 1, 2) != "  " || row ~ /^ *│$/) choice = ""
      if (choice != "") print choice "\t" NR
    }
  ' "$1"
}
