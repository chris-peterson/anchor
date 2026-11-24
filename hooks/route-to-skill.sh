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
# The skills' own write step runs through a script (scripts/release-publish.sh,
# scripts/prepare-review.sh), so the raw command never appears in the Bash call
# this hook sees: the script's path is the allowed route, with no marker to forge
# or keep in step.
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
#   route-cr        gh pr create / glab mr create, a CR description write
#                   (`gh pr edit --body*`, `glab mr update --description`), and
#                   the `gh api` / `glab api` writes that do either, GraphQL
#                   included -> /anchor:prepare-review. A title, label,
#                   milestone, base, reviewer, or draft-flag edit passes:
#                   batch edits and /anchor:stack make those, and
#                   prepare-review.sh writes none of them on an existing CR.
#
# Fails open: input it can't read, or a command it doesn't recognize, exits 0
# with nothing printed, and the call goes on to the normal permission flow.

set -uo pipefail

input=$(cat 2>/dev/null) || exit 0

# Cheap prefilter. Bash is the most frequent tool call there is, so a command
# that can't match leaves before anything else runs.
case "$input" in
  *release* | *workflow* | *dispatches*) ;;
  *pr[[:space:]]* | *mr[[:space:]]* | *pulls* | *merge_requests* | *PullRequest*) ;;
  *) exit 0 ;;
esac

if command -v jq >/dev/null 2>&1; then
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
else
  # No jq: lift the command string out of the JSON and decode the escapes that
  # matter here, so what follows sees the command as jq would have returned it.
  # An escaped backslash is set aside first, so `\\n` stays a backslash and an n.
  re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ "$input" =~ $re ]] || exit 0
  cmd=${BASH_REMATCH[1]}
  bs=$'\\' held=$'\x01'
  cmd=${cmd//"$bs$bs"/"$held"}
  cmd=${cmd//"${bs}n"/$'\n'}
  cmd=${cmd//"${bs}t"/$'\t'}
  cmd=${cmd//"$bs\""/\"}
  cmd=${cmd//"$held"/"$bs"}
fi
[[ -n "$cmd" ]] || exit 0

# The body of a heredoc with a quoted delimiter (<<'EOF', <<"EOF", <<\EOF) is
# literal text the shell never runs — a doc being written, a commit message, a
# script handed to an interpreter — and it names these commands often. Drop it,
# so prose that mentions `gh pr create` isn't read as a call to it. An unquoted
# heredoc still expands $(…) and backticks, so its body stays.
heredoc="<<-?[[:space:]]*(['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]|\\\\([A-Za-z_][A-Za-z0-9_]*))"
if [[ "$cmd" == *"<<"* ]]; then
  kept="" delim=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$delim" ]]; then
      stripped="${line#"${line%%[!$'\t']*}"}"
      [[ "$stripped" == "$delim" ]] && delim=""
      continue
    fi
    kept+="$line"$'\n'
    if [[ "$line" =~ $heredoc ]]; then
      delim="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    fi
  done <<<"$cmd"
  cmd=$kept
fi

# One line, so a segment is everything between two separators. A `\`-continued
# line is still the same command, so it joins with a space first; otherwise the
# fields of a multi-line `gh api` call would fall into a segment of their own.
cmd=${cmd//$'\\\n'/ }
cmd=${cmd//$'\n'/;}

# A command position: the start, after a separator or an opening `(` / `$(`, or
# after a shell keyword that starts a command — then any VAR=value prefixes.
pos='(^|[;&|(`]|\$\(|(^|[[:space:]])(do|then|else|exec|command|env|time))[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
seg='([^;&|]*)'

# deny <rule> <what> <skill> <how the skill does it>
deny() {
  local rule="$1" what="$2" skill="$3" how="$4" reason
  reason="[anchor:$rule] $what is blocked here; it belongs to $skill. "
  reason+="Invoke that skill (or, if it is already running, take its own step for this): $how "
  reason+="Do not hand this command to the user to run with ! or in their shell; that skips the same gates."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

deny_release() {
  deny route-release "$1" /anchor:release \
    "it establishes the release model, confirms the publish with the user as its own question, and publishes through scripts/release-publish.sh, which this guard allows. An approval of the notes or of the notes commit is not approval to publish."
}

deny_cr() {
  deny route-cr "$1" /anchor:prepare-review \
    "it stops on uncommitted or unpushed work so the description matches the code the branch carries, opens the CR as a draft, composes the project's template and the Review guide, has the user approve the exact text, backs up the description it replaces, and writes through scripts/prepare-review.sh (--open, --write), which this guard allows."
}

# An API call that writes: a non-GET method, or fields without an explicit GET
# (fields make `gh api` / `glab api` POST by default).
api_writes() {
  local args="$1"
  local method='(-X|--method)[[:space:]=]*["'"'"']?(POST|PUT|PATCH)'
  local get='(-X|--method)[[:space:]=]*["'"'"']?GET'
  local fields='(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'
  [[ "$args" =~ $method ]] && return 0
  [[ "$args" =~ $get ]] && return 1
  [[ "$args" =~ $fields ]]
}

# gh/glab release create
re="${pos}(gh|glab)[[:space:]]+release[[:space:]]+create([[:space:]]|$)"
[[ "$cmd" =~ $re ]] && deny_release "A raw \`release create\`"

# gh workflow run: only a release workflow. A docs deploy or a lint rerun has no
# skill, and the deny must never name one that can't do the job.
re="${pos}gh[[:space:]]+workflow[[:space:]]+run${seg}"
if [[ "$cmd" =~ $re ]]; then
  args="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  level="=[\"']?(major|minor|patch)([\"'[:space:]]|\$)"
  if [[ "$args" == *release* || "$args" =~ $level ]]; then
    deny_release "A raw release-workflow dispatch"
  fi
fi

# The API spellings of the same two writes. A GET of a release passes.
re="${pos}(gh|glab)[[:space:]]+api${seg}"
if [[ "$cmd" =~ $re ]]; then
  args="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  releases="/releases([/?\"'[:space:]]|\$)"
  if [[ "$args" =~ $releases || "$args" == */dispatches* ]]; then
    if api_writes "$args"; then
      deny_release "A raw release write through the forge API"
    fi
  fi
fi

# gh pr create / glab mr create
re="${pos}(gh[[:space:]]+pr|glab[[:space:]]+mr)[[:space:]]+create([[:space:]]|$)"
[[ "$cmd" =~ $re ]] && deny_cr "A raw CR create"

# A description edit: gh pr edit --body / -b / --body-file / -F, and glab mr
# update --description / -d / --description-file, --attach (appends to the
# description), or --fill / -f (rewrites it from the commits). Every other edit
# flag passes.
re="${pos}(gh[[:space:]]+pr[[:space:]]+edit|glab[[:space:]]+mr[[:space:]]+update)${seg}"
if [[ "$cmd" =~ $re ]]; then
  args="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  body='(^|[[:space:]])(--body|--body-file|-b|-F|--description|--description-file|-d|--attach|--fill|-f)([[:space:]=]|$)'
  [[ "$args" =~ $body ]] && deny_cr "A raw CR description write"
fi

# The API spellings. A create is a write to the collection (`…/pulls`,
# `…/merge_requests`); a description edit is a write to one CR carrying a
# `body` / `description` field. Its notes, discussions, blocks, and reviews are
# paths below the CR and pass here.
re="${pos}(gh|glab)[[:space:]]+api${seg}"
if [[ "$cmd" =~ $re ]]; then
  args="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  end="([?\"'[:space:]]|\$)"
  collection="/(pulls|merge_requests)${end}"
  item="/(pulls|merge_requests)/[^/?\"'[:space:]]+${end}"
  descfield="(^|[[:space:]=\"'])(body|description)="
  if api_writes "$args"; then
    [[ "$args" =~ $collection ]] && deny_cr "A raw CR create through the forge API"
    [[ "$args" =~ $item && "$args" =~ $descfield ]] && deny_cr "A raw CR description write through the forge API"
  fi
  # GraphQL: always a POST, so the mutation names the write.
  if [[ "$args" == *graphql* ]]; then
    [[ "$args" == *createPullRequest* ]] && deny_cr "A raw CR create through GraphQL"
    [[ "$args" == *updatePullRequest* && "$args" =~ (^|[^A-Za-z])body[[:space:]]*: ]] \
      && deny_cr "A raw CR description write through GraphQL"
  fi
fi

exit 0
