#!/usr/bin/env bash
# Copy each skills/*/SKILL.md into docs/skills/<name>.md, stripping the YAML
# frontmatter (the leading --- ... --- block), and each rules/*.md into
# docs/rules/<name>.md, so the docs site renders each source of truth directly
# with no parallel doc artifact to maintain.
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
