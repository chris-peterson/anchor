#!/usr/bin/env bash
# PreToolUse hook on Bash: deny a raw forge mutation that an anchor skill owns,
# and name the skill in the reason.
#
# The ambient rules ask the agent to route these through the skills, and asking
# is all they do. A session that loses the thread mid-skill — a compaction, a
# denied call it routes around, a confirmation it reads off an earlier "lgtm" —
# reaches for the bare command, or hands it to the user to run with `!`. The rule
# is already in context at that moment and didn't hold; a deny does, in every
# permission mode.
#
# The skills' own publish step runs through a script (scripts/release-publish.sh),
# so the raw command never appears in the Bash call this hook sees: the script's
# path is the allowed route, with no marker to forge or keep in step.
#
# Each rule's reason opens with a stable marker, `[anchor:<rule>]`, so a
# transcript count can tell how often each one fires and whether the next call
# followed it.
#
# Rules, so far:
#   route-release   gh/glab `release create`, a release-workflow dispatch
#                   (`gh workflow run` naming a release workflow or passing a
#                   semver level), and the `gh api` / `glab api` writes that do
#                   either -> /anchor:release
#
# Fails open: input it can't read, or a command it doesn't recognize, exits 0
# with nothing printed, and the call goes on to the normal permission flow.

set -uo pipefail

input=$(cat 2>/dev/null) || exit 0

# Cheap prefilter. Bash is the most frequent tool call there is, so a command
# that can't match leaves before anything else runs.
case "$input" in
  *release* | *workflow* | *dispatches*) ;;
  *) exit 0 ;;
esac

if command -v jq >/dev/null 2>&1; then
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
else
  # No jq: scan the raw JSON. Escaped newlines still separate commands.
  cmd=${input//\\n/;}
fi
[[ -n "$cmd" ]] || exit 0

# One line, so a segment is everything between two separators.
cmd=${cmd//$'\n'/;}

# A command position: the start, after a separator or an opening `(` / `$(`, or
# after a shell keyword that starts a command — then any VAR=value prefixes.
pos='(^|[;&|(`]|\$\(|(^|[[:space:]])(do|then|else|exec|command|env|time))[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
seg='([^;&|]*)'

deny() {
  local rule="$1" what="$2" reason
  reason="[anchor:$rule] $what is blocked here; it belongs to /anchor:release. "
  reason+="Invoke that skill (or, if it is already running, take its publish step): "
  reason+="it establishes the release model, confirms the publish with the user as its own question, "
  reason+="and publishes through scripts/release-publish.sh, which this guard allows. "
  reason+="An approval of the notes or of the notes commit is not approval to publish. "
  reason+="Do not hand this command to the user to run with ! or in their shell; that skips the same gates."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

# gh/glab release create
re="${pos}(gh|glab)[[:space:]]+release[[:space:]]+create([[:space:]]|$)"
[[ "$cmd" =~ $re ]] && deny route-release "A raw \`release create\`"

# gh workflow run: only a release workflow. A docs deploy or a lint rerun has no
# skill, and the deny must never name one that can't do the job.
re="${pos}gh[[:space:]]+workflow[[:space:]]+run${seg}"
if [[ "$cmd" =~ $re ]]; then
  args="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  level="=[\"']?(major|minor|patch)([\"'[:space:]]|\$)"
  if [[ "$args" == *release* || "$args" =~ $level ]]; then
    deny route-release "A raw release-workflow dispatch"
  fi
fi

# The API spellings of the same two writes. A GET of a release passes; a write
# is a non-GET method, or fields, which make `gh api` POST by default.
re="${pos}(gh|glab)[[:space:]]+api${seg}"
if [[ "$cmd" =~ $re ]]; then
  args="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  write='(-X|--method)[[:space:]=]*(POST|PUT|PATCH)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'
  releases="/releases([/?\"'[:space:]]|\$)"
  if [[ "$args" =~ $releases || "$args" == */dispatches* ]]; then
    if [[ "$args" =~ $write ]]; then
      deny route-release "A raw release write through the forge API"
    fi
  fi
fi

exit 0
