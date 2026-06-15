#!/usr/bin/env bash
# Render the docs site from each source of truth, so there's no parallel doc
# artifact to maintain:
#   skills/*/SKILL.md -> docs/skills/<name>.md  (YAML frontmatter stripped)
#   rules/*.md        -> docs/rules/<name>.md
#   guides/*.md       -> docs/guides/<name>.md
#   templates/*.md    -> docs/templates/<name>.md
# The guides/ and templates/ files are load-bearing — skills read them at runtime
# via ${CLAUDE_PLUGIN_ROOT}/<dir>/<name>.md — so docs/ stays a pure render target.
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

mkdir -p docs/templates
cp templates/*.md docs/templates/

# Render the suite: block to docs/suite.json for the live session preview.
python3 scripts/gen-suite-json.py
