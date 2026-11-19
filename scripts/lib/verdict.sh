#!/usr/bin/env bash
# The Review box of a revdiff review's (context).md: what the reviewer does in
# this step, and nothing about what happens after it. Three sections, each a
# run of keys in one column: moving between changes, leaving notes, and being
# done. revdiff quits one way and exits the same for "nothing to say" as for
# "discarded what I said", so a quit with nothing in it is asked about in the
# pane (DIFF-49), and `ZZ` and `ZQ` are that quit and its answer typed together.
#
# Sourced only; the caller sources lib/callout.sh and lib/hints.sh first.
#
#   anchor_review_box [--about <text>] <slug> <bin> <approve> <reject>
#                         the box for a review that ends approved or rejected:
#                         <approve> and <reject> are what the `ZZ` and `ZQ`
#                         rows say. With hints on (anchor.<slug>.hints,
#                         CONFIG-21), <bin>'s keys come first, then <about>,
#                         then the done rows, and the box closes on how to
#                         dismiss the hints; with hints off it holds the done
#                         rows alone
#   anchor_items_box <bin>
#                         the box for a review of items (a batch, a review
#                         round's items pass), whose choice the pane's confirm
#                         dialog asks for, so it is done with `q` alone; with
#                         hints off it holds that row alone
#   anchor_verdict_lines <file>
#                         where the choices sit in <file>, as `accept\t<n>` and
#                         `reject\t<n>` for the `ZZ` and `ZQ` rows, and each
#                         other row of the box's own text as `hints\t<n>`: a
#                         note there is the reviewer dismissing the hints;
#                         nothing for a file without the box

ANCHOR_REVIEW_BOX_TITLE="Review"
ANCHOR_REVIEW_DISMISS='*Add a note on this line to dismiss these hints.*'

anchor_review_box() {
  local about="" finish keys
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --about) about=$2 ;;
      *) echo "anchor_review_box: unknown option $1" >&2; return 64 ;;
    esac
    shift 2
  done
  finish=$(anchor_box_key q done; anchor_box_key ZZ "$3"; anchor_box_key ZQ "$4")
  if ! anchor_hints_on "$1"; then
    anchor_box "$finish" "$ANCHOR_REVIEW_BOX_TITLE"
    return
  fi
  keys=$(anchor_revdiff_hints "$2")
  anchor_box "$(printf '%s\n' \
    ${keys:+"$keys"} ${keys:+''} \
    ${about:+"$about"} ${about:+''} \
    "$finish" '' \
    "$ANCHOR_REVIEW_DISMISS")" \
    "$ANCHOR_REVIEW_BOX_TITLE"
}

# shellcheck disable=SC2016
anchor_items_box() {
  local keys finish
  finish=$(anchor_box_key q "done, then confirm")
  if ! anchor_hints_on items; then
    anchor_box "$finish" "$ANCHOR_REVIEW_BOX_TITLE"
    return
  fi
  keys=$(anchor_revdiff_hints "$1")
  anchor_box "$(printf '%s\n' \
    ${keys:+"$keys"} ${keys:+''} \
    'Answer each item on its note:' \
    '- accept it: do nothing' \
    '- edit it: say what you want instead' \
    '- skip it: say `skip`' \
    'Note anywhere else to add something new.' \
    '' \
    "$finish" '' \
    "$ANCHOR_REVIEW_DISMISS")" \
    "$ANCHOR_REVIEW_BOX_TITLE"
}

anchor_verdict_lines() {
  [[ -f "$1" ]] || return 0
  awk -v top="╭─ $ANCHOR_REVIEW_BOX_TITLE " '
    index($0, top) == 1 { on = 1; next }
    on && /^╰/ { exit }
    on {
      row = $0; sub(/^│ /, "", row)
      if (index(row, "`ZZ` ") == 1) print "accept\t" NR
      else if (index(row, "`ZQ` ") == 1) print "reject\t" NR
      else if (row !~ /^ *│$/) print "hints\t" NR
    }
  ' "$1"
}
