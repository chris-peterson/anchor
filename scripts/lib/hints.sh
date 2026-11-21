#!/usr/bin/env bash
# The lines a review's context names the review tool's keys in, for a reviewer
# new to the tool, and the switch that hides them once they know the keys.
#
# Sourced only.
#
#   anchor_hints_on <qualifier>   whether the hints are wanted: anchor.<qualifier>.hints,
#                                 else anchor.hints, else true (CONFIG-21). The
#                                 qualifier is `edit` for an editor review, and
#                                 for a diff review the Review box's own slug:
#                                 `diff`, `review-read`, or `items`
#   anchor_revdiff_hints <bin>    revdiff's keys for stepping and annotating, read
#                                 from the bindings <bin> has
#   anchor_hints_off              how to hide the hints, last in an editor
#                                 review's box

anchor_hints_on() {
  local key v rc
  for key in "anchor.$1.hints" anchor.hints; do
    rc=0
    v=$(git config --type=bool --get "$key") || rc=$?
    [[ "$rc" -eq 0 ]] && { [[ "$v" == true ]]; return; }
  done
  return 0
}

# The first key `--dump-keys` output on stdin maps to action $1, as inline code.
# shellcheck disable=SC2016
anchor_revdiff_key() {
  awk -v a="$1" '$1 == "map" && $3 == a { printf "`%s`", $2; exit }'
}

# Read from the bindings this revdiff actually has, so a remapped key is named
# as remapped: the hunk keys on one row, back on the left and on on the right,
# where the arrows cue the direction, then, after a blank row, one key row
# (lib/callout.sh's anchor_box_key) for each kind of note. A key whose action
# has none is left out, and a row with neither. The tab splits the hunk row
# across the box.
anchor_revdiff_hints() {
  local keys
  keys=$("$1" --dump-keys) || {
    echo "$1 --dump-keys failed, so (context).md names no keys" >&2
    return 0
  }
  local next prev line_note file_note out="" notes=""
  next=$(anchor_revdiff_key next_hunk <<<"$keys"); prev=$(anchor_revdiff_key prev_hunk <<<"$keys")
  line_note=$(anchor_revdiff_key confirm <<<"$keys"); file_note=$(anchor_revdiff_key annotate_file <<<"$keys")
  [[ -z "$prev$next" ]] || out="${prev:+$prev ← prev}"$'\t'"${next:+next → $next}"$'\n'
  [[ -z "$line_note" ]] || notes+=$(anchor_box_key "${line_note//\`/}" "note this line")$'\n'
  [[ -z "$file_note" ]] || notes+=$(anchor_box_key "${file_note//\`/}" "note this file")$'\n'
  [[ -z "$notes" ]] || out+="${out:+$'\n'}$notes"
  printf '%s' "$out"
}

# In italics, since it is for the reader who already knows the keys.
anchor_hints_off() {
  printf '%s\n' '*Tell the agent "hide hints" to stop showing this box.*'
}
