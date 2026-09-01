#!/usr/bin/env bash
# Publish one interop announcement on stdout, for a sibling plugin to react to.
#
#   announce.sh cr.described CR_IID=88 CR_URL=https://github.com/o/r/pull/88
#   -> codes.bridgeai.anchor/cr.described CR_IID=88 CR_URL=https://github.com/o/r/pull/88
#
# The canonical guide is the suite's interop contract, which owns the grammar,
# the payload rules, and the reasoning behind both:
# https://github.com/chris-peterson/claude-marketplace/blob/main/authoring/plugin-contract.md
#
# Every announcement anchor makes comes through here, so the shape is checked in
# one place rather than in each emitting script. The plugin segment is fixed
# rather than an argument: a plugin announces facts it caused, never one it
# observed a sibling cause.
#
# Exits 0 on every path, malformed calls included — see the contract's
# publishing rules. This runs after the work it describes has landed, so turning
# an operation that succeeded into a tool call that failed is the one outcome it
# must never produce.

set -uo pipefail

readonly PLUGIN=anchor

key="${1:-}"
[[ $# -gt 0 ]] && shift

if [[ ! $key =~ ^[a-z0-9]+\.[a-z0-9]+$ ]]; then
  echo "announce.sh: expected <entity>.<event> in lowercase, got: ${key:-<empty>}" >&2
  exit 0
fi

line="codes.bridgeai.${PLUGIN}/${key}"

for kv in "$@"; do
  if [[ ! $kv =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]*$ ]]; then
    echo "announce.sh: payload must be KEY=value with no whitespace, got: $kv" >&2
    exit 0
  fi
  line="$line $kv"
done

printf '%s\n' "$line"
exit 0
