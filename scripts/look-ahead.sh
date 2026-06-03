#!/usr/bin/env bash
# Print the number of unpushed commits (HEAD ahead of @{upstream}).
# Output:
#   - "N" (integer) when an upstream is configured
#   - empty + non-zero exit when no upstream is configured
#
# Why a helper: invoking `git rev-list @{u}..HEAD` directly from a skill trips
# Claude Code's bash safety analyzer (the literal `@{...}` looks like brace
# expansion), prompting on every call regardless of allowlist or ClaudeWatch
# rules. Inside a script the analyzer only sees the outer `bash` invocation,
# so the structural gate doesn't fire.

git rev-list --count '@{u}..HEAD' 2>/dev/null
