# shipyard runs from its git ref, with no checkout and no install. CI is the
# writer for what lands; these recipes are for seeing the projection first.
shipyard := "uvx --from 'git+https://github.com/chris-peterson/shipyard@v2' shipyard"

default:
    @just --list

# project source into the generated artifacts (plugin.json, hooks.json, describe, docs)
generate:
    {{shipyard}} generate

# render the docsify docs site and serve it locally
docs:
    {{shipyard}} build-docs
    docsify serve docs --open

# lint the shell scripts (mirrors the lint.yml CI job)
lint:
    shellcheck hooks/*.sh scripts/*.sh scripts/review/*.sh tests/*.sh

# run every test suite that declares this platform (test.yml runs the same script)
test:
    bash tests/run-all.sh
