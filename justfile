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

# run every test.yml CI job locally, in the same grouping
test: test-tmpfile test-commit test-prepare-review test-release-recon test-pipeline test-config-defaults test-review test-review-cr

# test.yml: tmpfile — the temp-path helper and deep-link anchors
test-tmpfile:
    bash tests/tmpfile.test.sh
    bash tests/deep-links.test.sh

# test.yml: commit — scripts/commit.sh end-to-end and its preflight
test-commit:
    bash tests/commit.test.sh
    bash tests/commit-preflight.test.sh

# test.yml: prepare-review — the branch-deletion read against stub gh/glab
test-prepare-review:
    bash tests/prepare-review.test.sh

# test.yml: release — scripts/release-recon.sh per release model
test-release-recon:
    bash tests/release-recon.test.sh

# test.yml: pipeline — scripts/pipeline-status.sh and its after-push caller
test-pipeline:
    bash tests/pipeline-status.test.sh
    bash tests/pipeline-after-push.test.sh

# test.yml: config-defaults — the six sources of truth for verbosity defaults agree
test-config-defaults:
    bash tests/config-defaults.test.sh

# test.yml: review — the review dispatcher and its revdiff/editor adapters
test-review:
    bash tests/review-diff.test.sh
    bash tests/review-editor.test.sh

# test.yml: review-cr — reaching a CR head and posting findings against stub gh/glab
test-review-cr:
    bash tests/review-cr.test.sh
    bash tests/review-post.test.sh
