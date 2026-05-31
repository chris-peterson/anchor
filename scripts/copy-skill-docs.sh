#!/usr/bin/env bash
# Sync the plugin's source-of-truth markdown into the docs site so it renders
# each skill and guide directly, with no parallel doc artifact to maintain.
# Used by `just docs` and the GitHub Pages deploy workflow.
#
#   skills/*/SKILL.md  -> docs/skills/<name>.md   (YAML frontmatter stripped)
#   guides/*.md        -> docs/guides/<name>.md   (copied verbatim)

set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p docs/skills
for skill in skills/*/SKILL.md; do
  name=$(basename "$(dirname "$skill")")
  awk '/^---$/{fm++; next} fm>=2' "$skill" > "docs/skills/$name.md"
done

mkdir -p docs/guides
for guide in guides/*.md; do
  cp "$guide" "docs/guides/$(basename "$guide")"
done
