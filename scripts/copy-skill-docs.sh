#!/usr/bin/env bash
# Render the docs site from each source of truth, so there's no parallel doc
# artifact to maintain:
#   skills/*/SKILL.md -> docs/skills/<name>.md  (YAML frontmatter stripped)
#   rules/*.md        -> docs/rules/<name>.md
#   guides/*.md       -> docs/guides/<name>.md
# The guides/ files are load-bearing — skills and rules read them at runtime via
# ${CLAUDE_PLUGIN_ROOT}/guides/<name>.md — so docs/ stays a pure render target.
# Used by `just docs` and the GitHub Pages deploy workflow.

set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p docs/skills
for skill in skills/*/SKILL.md; do
  name=$(basename "$(dirname "$skill")")
  awk '/^---$/{fm++; next} fm>=2' "$skill" > "docs/skills/$name.md"
done

mkdir -p docs/rules
cp rules/*.md docs/rules/

mkdir -p docs/guides
cp guides/*.md docs/guides/
