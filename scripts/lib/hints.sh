#!/usr/bin/env bash
# The lines a review's context names the review tool's keys in, for a reviewer
# new to the tool, and the switch that hides them once they know the keys.
#
# Sourced only.
#
#   anchor_hints_on <qualifier>   whether the hints are wanted: anchor.<qualifier>.hints,
#                                 else anchor.hints, else true (CONFIG-21)
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
# then one key for each kind of annotation. A row whose action has no key is
# left out. The tab splits a row across the box (lib/callout.sh).
anchor_revdiff_hints() {
  local keys
  keys=$("$1" --dump-keys) || {
    echo "$1 --dump-keys failed, so (context).md names no keys" >&2
    return 0
  }
  local next prev line_note file_note out=""
  next=$(anchor_revdiff_key next_hunk <<<"$keys"); prev=$(anchor_revdiff_key prev_hunk <<<"$keys")
  line_note=$(anchor_revdiff_key confirm <<<"$keys"); file_note=$(anchor_revdiff_key annotate_file <<<"$keys")
  if [[ -n "$prev$next" ]]; then
    out="${prev:+$prev ← prev}"$'\t'"${next:+next → $next}"$'\n\n'
  fi
  if [[ -n "$line_note$file_note" ]]; then
    out+="To add an annotation:"$'\n'
    [[ -z "$line_note" ]] || out+="$line_note to the current line"$'\n'
    [[ -z "$file_note" ]] || out+="$file_note to the current file"$'\n'
  fi
  printf '%s' "$out"
}

# In italics, since it is for the reader who already knows the keys.
anchor_hints_off() {
  printf '%s\n' '*Tell the agent "hide hints" to stop showing this box.*'
}
