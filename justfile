default:
    @just --list

# regenerate all generated artifacts from source (describe, plugin.json, docs)
generate:
    scripts/shipyard generate

# validate source projects cleanly and preview the pending projection (no write)
check:
    scripts/shipyard generate --dry-run

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

# lint the shell scripts (mirrors the lint.yml CI job)
lint:
    shellcheck hooks/*.sh scripts/*.sh scripts/review/*.sh tests/*.sh

# run every test suite that declares this platform (test.yml runs the same script)
test:
    bash tests/run-all.sh
