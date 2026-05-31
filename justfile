default:
    @just --list

# preview the docsify docs site locally
docs:
    bash scripts/copy-skill-docs.sh
    docsify serve docs --open
