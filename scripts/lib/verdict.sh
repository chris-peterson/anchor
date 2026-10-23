#!/usr/bin/env bash
# The Verdict section of a revdiff review's (context).md: two lines the reviewer
# chooses between by leaving a note on one. revdiff quits one way and exits the
# same for "nothing to say" as for "discarded what I said", so the choice has to
# be written down, and a quit that writes none is asked about rather than read.
#
# Sourced only.
#
#   anchor_verdict_section <accept> <reject>
#                         the section, naming what each choice leads to
#   anchor_verdict_lines <file>
#                         where the choices sit in <file>, as `accept\t<n>` and
#                         `reject\t<n>`; nothing for a file without the section

ANCHOR_VERDICT_HEADING="## Verdict"

# shellcheck disable=SC2016
anchor_verdict_section() {
  printf '%s\n' "$ANCHOR_VERDICT_HEADING" \
    'Choose by leaving a note (any text) on one of these lines, then quit with `q`:' \
    "- **Accept**: $1" \
    "- **Reject**: $2" \
    'With a note on neither, your notes go back for a revision you review again.' \
    'A review whose only note says `lgtm`, `ship it`, or `approve` accepts, and one saying `reject`, `stop`, `abort`, or `cancel` rejects.'
}

anchor_verdict_lines() {
  [[ -f "$1" ]] || return 0
  awk -v h="$ANCHOR_VERDICT_HEADING" '
    $0 == h { on = 1; next }
    on && /^## / { exit }
    on && index($0, "- **Accept**:") == 1 { print "accept\t" NR }
    on && index($0, "- **Reject**:") == 1 { print "reject\t" NR }
  ' "$1"
}
