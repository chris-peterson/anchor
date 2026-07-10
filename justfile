default:
    @just --list

# regenerate all generated artifacts from source (describe, plugin.json, docs)
build:
    scripts/shipyard build

# verify committed generated artifacts (plugin.json, describe) match source
check:
    scripts/shipyard check

# preview the docsify docs site locally
docs:
    scripts/shipyard build-docs
    docsify serve docs --open

# regenerate .claude-plugin/plugin.json from plugin.yml (the canonical descriptor)
plugin-json:
    scripts/shipyard gen-plugin-json

# resync plugin.yml suite.describe from the skills/rules/hooks sources
describe:
    scripts/shipyard gen-describe

# install the git pre-commit hook that keeps generated artifacts in sync
install-hooks:
    cp scripts/hooks/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    @echo "installed .git/hooks/pre-commit"
