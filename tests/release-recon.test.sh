#!/usr/bin/env bash
# Functional test for scripts/release-recon.sh — the release facts the `release`
# skill reads instead of deriving. The load-bearing assertions are the four
# RELEASE_MODEL verdicts (who owns the version bump) and the two cases a grep
# would get wrong: a `release:` job name under `jobs:`, and a manifest that is
# generated from a canonical descriptor.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
recon="$here/../scripts/release-recon.sh"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-release-recon-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# A repo with one seed commit, no version artifact of any kind.
new_repo() {
  local repo="$work/$1"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m seed
  echo "$repo"
}

run() { bash "$recon" --repo "$1"; }

# --- no-version-artifact: nothing to bump, the merge already was the release ---
repo=$(new_repo iac)
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "no-version-artifact" ] \
  || fail "a repo with no manifest should be no-version-artifact: $(val RELEASE_MODEL "$o")"
[ -z "$(val RELEASE_MANIFEST "$o")" ] || fail "expected no manifest: $o"
[ -z "$(val RELEASE_VERSION "$o")" ] || fail "expected no version: $o"
[ "$(val RELEASE_LAST_REF_KIND "$o")" = "root" ] \
  || fail "with no tag and no bump, the anchor is the root commit: $o"
ok "no manifest, no release CI -> no-version-artifact"

# --- bump-commit: a manifest, no release CI, so the bump is a commit here ------
repo=$(new_repo node)
printf '{\n  "name": "x",\n  "version": "0.3.0"\n}\n' > "$repo/package.json"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "add manifest"
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "bump-commit" ] \
  || fail "a manifest with no release CI should be bump-commit: $(val RELEASE_MODEL "$o")"
[ "$(val RELEASE_MANIFEST "$o")" = "package.json" ] || fail "manifest wrong: $o"
[ "$(val RELEASE_VERSION "$o")" = "0.3.0" ] || fail "version wrong: $o"
ok "manifest + no release CI -> bump-commit, version read from package.json"

# bump-commit reviews the notes as part of the commit, so it needs no baseline.
[ -z "$(val RELEASE_NOTES_BASELINE "$o")" ] \
  || fail "bump-commit reviews notes in the commit, so no baseline: $o"
ok "bump-commit gets no notes baseline"

# The manifest arrived carrying 0.3.0, which counts as a bump (nothing -> 0.3.0);
# what matters for the never-versioned carve-out is that a *second* bump lands.
[ "$(val RELEASE_VERSION_BUMPS "$o")" = "1" ] || fail "expected 1 bump: $o"
[ "$(val RELEASE_LAST_REF_KIND "$o")" = "bump-commit" ] \
  || fail "with no tags, the last version-change commit anchors the range: $o"
ok "no tags -> the manifest's last version-change commit is the anchor"

# A bump commit carrying only bookkeeping (manifest + CHANGELOG) stood alone.
printf '{\n  "name": "x",\n  "version": "0.4.0"\n}\n' > "$repo/package.json"
printf '# Changelog\n\n## 0.4.0\n' > "$repo/CHANGELOG.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "Release 0.4.0"
o=$(run "$repo")
[ "$(val RELEASE_BUMP_CONVENTION "$o")" = "standalone" ] \
  || fail "a bookkeeping-only bump stands alone: $(val RELEASE_BUMP_CONVENTION "$o")"
[ "$(val RELEASE_VERSION_BUMPS "$o")" = "2" ] || fail "expected 2 bumps: $o"
[ "$(val RELEASE_CHANGELOG_HAS_CURRENT "$o")" = "1" ] \
  || fail "0.4.0 has a changelog section, so it looks already shipped: $o"
[ "$(val RELEASE_CHANGELOG_UNRELEASED "$o")" = "0" ] || fail "no Unreleased section here: $o"
ok "a bookkeeping-only bump reads as standalone"

# A bump riding real source work is folded; both shapes present is mixed.
printf '{\n  "name": "x",\n  "version": "0.5.0"\n}\n' > "$repo/package.json"
printf 'feature\n' > "$repo/app.js"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "add the widget"
o=$(run "$repo")
[ "$(val RELEASE_BUMP_CONVENTION "$o")" = "mixed" ] \
  || fail "one folded + one standalone bump is mixed: $(val RELEASE_BUMP_CONVENTION "$o")"
[ "$(val RELEASE_VERSION_BUMPS "$o")" = "3" ] || fail "expected 3 bumps: $o"
ok "a bump riding source work reads as folded -> mixed"

printf '# Changelog\n\n## Unreleased\n\n## 0.4.0\n' > "$repo/CHANGELOG.md"
o=$(run "$repo")
[ "$(val RELEASE_CHANGELOG_UNRELEASED "$o")" = "1" ] || fail "Unreleased not detected: $o"
[ "$(val RELEASE_DIRTY "$o")" = "1" ] || fail "uncommitted CHANGELOG edit should read dirty: $o"
ok "Unreleased section + dirty tree detected"
git -C "$repo" checkout --quiet -- CHANGELOG.md

# A tag outranks the manifest history as the last-shipped anchor.
git -C "$repo" tag v0.4.0
printf 'more\n' >> "$repo/README.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "a change since the tag"
o=$(run "$repo")
[ "$(val RELEASE_LAST_REF "$o")" = "v0.4.0" ] || fail "the tag should anchor: $o"
[ "$(val RELEASE_LAST_REF_KIND "$o")" = "tag" ] || fail "kind should be tag: $o"
[ "$(val RELEASE_RANGE "$o")" = "v0.4.0..HEAD" ] || fail "range wrong: $o"
[ "$(val RELEASE_COMMITS "$o")" = "1" ] || fail "expected 1 commit since the tag: $o"
ok "a version tag outranks manifest history as the anchor"

# --- release-triggered: CI owns the bump, so never hand-edit the manifest -----
# The workflow also has a *job* named `release`, at the same indent the trigger
# would sit at. Distinguishing them is the reason this is a script.
repo=$(new_repo plugin)
mkdir -p "$repo/.github/workflows" "$repo/.claude-plugin"
cat > "$repo/.github/workflows/release.yml" <<'YAML'
name: Release
on:
  release:
    types: [published]
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo publish
YAML
printf 'name: p\nversion: 2.1.0\n' > "$repo/plugin.yml"
printf '{\n  "name": "p",\n  "version": "2.1.0"\n}\n' > "$repo/.claude-plugin/plugin.json"
printf 'plugin-json:\n    scripts/gen --plugin-json\n' > "$repo/justfile"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m "add plugin"
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "release-triggered" ] \
  || fail "on: release: should be release-triggered: $(val RELEASE_MODEL "$o")"
[ "$(val RELEASE_WORKFLOW "$o")" = ".github/workflows/release.yml" ] || fail "workflow wrong: $o"
ok "on: release: -> release-triggered (not confused by the release: job)"

# The notes review only runs where the notes become a published release body, so
# the baseline is created for those models and left empty for the others.
base=$(val RELEASE_NOTES_BASELINE "$o")
[ -n "$base" ] || fail "a release-triggered repo should get a notes baseline: $o"
[ -f "$base" ] || fail "the baseline should exist for the review to diff against: $base"
[ ! -s "$base" ] || fail "the baseline should be empty: $base"
[ -n "$(val RELEASE_NOTES_PATH "$o")" ] || fail "expected a notes draft path: $o"
[ ! -e "$(val RELEASE_NOTES_PATH "$o")" ] || fail "the draft path should not be created: $o"
rm -f "$base"
ok "notes draft path supplied, baseline created empty"

[ "$(val RELEASE_MANIFEST "$o")" = ".claude-plugin/plugin.json" ] || fail "manifest wrong: $o"
[ "$(val RELEASE_MANIFEST_SOURCE "$o")" = "plugin.yml" ] \
  || fail "the generated manifest's source should be plugin.yml: $o"
[ "$(val RELEASE_MANIFEST_REGEN "$o")" = "just plugin-json" ] \
  || fail "regen command wrong: $o"
[ "$(val RELEASE_VERSION "$o")" = "2.1.0" ] || fail "version wrong: $o"
ok "generated manifest -> source descriptor + regen command surfaced"

# A workflow with only a `release:` *job* and a push trigger is not a release
# model — the inverse of the case above, and the one a bare grep gets wrong.
repo=$(new_repo jobname)
mkdir -p "$repo/.github/workflows"
cat > "$repo/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo not-a-release-trigger
YAML
printf '{\n  "version": "1.0.0"\n}\n' > "$repo/package.json"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m ci
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "bump-commit" ] \
  || fail "a release: job under jobs: is not a release trigger: $(val RELEASE_MODEL "$o")"
[ -z "$(val RELEASE_WORKFLOW "$o")" ] || fail "expected no release workflow: $o"
ok "a release: job under jobs: does not make a release-triggered repo"

# --- tag-triggered: a tag push drives the publish -----------------------------
repo=$(new_repo tagged)
mkdir -p "$repo/.github/workflows"
cat > "$repo/.github/workflows/publish.yml" <<'YAML'
name: Publish
on:
  push:
    tags: ['v*']
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo publish
YAML
printf '[project]\nversion = "0.9.2"\n' > "$repo/pyproject.toml"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m publish
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "tag-triggered" ] \
  || fail "on: push: tags: should be tag-triggered: $(val RELEASE_MODEL "$o")"
[ "$(val RELEASE_VERSION "$o")" = "0.9.2" ] || fail "pyproject version wrong: $o"
ok "on: push: tags: -> tag-triggered, version read from pyproject.toml"

# GitLab has no release-published event; a tag-gated pipeline is the shape.
repo=$(new_repo gitlab)
cat > "$repo/.gitlab-ci.yml" <<'YAML'
deploy:
  rules:
    - if: $CI_COMMIT_TAG
  script: echo ship
YAML
printf '0.2.0\n' > "$repo/VERSION"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m gitlab
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "tag-triggered" ] \
  || fail "a CI_COMMIT_TAG-gated pipeline should be tag-triggered: $(val RELEASE_MODEL "$o")"
[ "$(val RELEASE_VERSION "$o")" = "0.2.0" ] || fail "VERSION file wrong: $o"
ok "gitlab CI_COMMIT_TAG -> tag-triggered, version read from VERSION"

# --- dispatch-triggered: a release workflow someone runs by hand ---------------
# The escape-hatch trap: every workflow in a repo tends to carry
# `workflow_dispatch:`, so matching that alone names whichever file sorts first.
# Here `deploy-docs.yml` sorts ahead of `release.yml` and must not win.
repo=$(new_repo dispatch)
mkdir -p "$repo/.github/workflows"
cat > "$repo/.github/workflows/deploy-docs.yml" <<'YAML'
name: Deploy docs
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo docs
YAML
cat > "$repo/.github/workflows/release.yml" <<'YAML'
name: Release
on:
  workflow_dispatch:
    inputs:
      bump:
        description: How far to advance the version
        required: true
        type: choice
        options: [patch, minor, major]
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo ship
YAML
printf 'name: p\nversion: 1.4.0\n' > "$repo/plugin.yml"
mkdir -p "$repo/.claude-plugin"
printf '{\n  "name": "p",\n  "version": "1.4.0"\n}\n' > "$repo/.claude-plugin/plugin.json"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m dispatch
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "dispatch-triggered" ] \
  || fail "a dispatch-only release workflow should be dispatch-triggered: $(val RELEASE_MODEL "$o")"
[ "$(val RELEASE_WORKFLOW "$o")" = ".github/workflows/release.yml" ] \
  || fail "the release workflow should win over the alphabetically-first hatch: $o"
ok "workflow_dispatch on a release workflow -> dispatch-triggered (not deploy-docs)"

[ "$(val RELEASE_DISPATCH_INPUTS "$o")" = "bump" ] \
  || fail "declared dispatch inputs wrong: $(val RELEASE_DISPATCH_INPUTS "$o")"
[ "$(val RELEASE_DISPATCH_BUMP_INPUT "$o")" = "bump" ] \
  || fail "the level-carrying input should be named: $o"
ok "the workflow's declared inputs and its level input are reported"

# CI owns the bump here, so the notes are not a release body this skill writes.
[ -z "$(val RELEASE_NOTES_BASELINE "$o")" ] \
  || fail "dispatch-triggered notes ride a commit, so no notes baseline: $o"
ok "dispatch-triggered gets no notes baseline"

# --- a dispatched workflow that is not a release workflow ---------------------
# Nothing identifies it as one and it takes no level, so inference falls through
# to today's answer rather than naming a workflow that publishes nothing.
repo=$(new_repo hatch-only)
mkdir -p "$repo/.github/workflows"
cat > "$repo/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo build
YAML
printf '{\n  "name": "x",\n  "version": "2.0.0"\n}\n' > "$repo/package.json"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m hatch
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "bump-commit" ] \
  || fail "a manual-run hatch is not a release model: $(val RELEASE_MODEL "$o")"
[ -z "$(val RELEASE_DISPATCH_INPUTS "$o")" ] || fail "no dispatch model, so no inputs: $o"
ok "a plain workflow_dispatch hatch does not become a release model"

# --- release: alongside workflow_dispatch: stays release-triggered ------------
repo=$(new_repo both-triggers)
mkdir -p "$repo/.github/workflows"
cat > "$repo/.github/workflows/release.yml" <<'YAML'
name: Release
on:
  release:
    types: [published]
  workflow_dispatch:
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo ship
YAML
printf '{\n  "name": "x",\n  "version": "1.0.0"\n}\n' > "$repo/package.json"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m both
o=$(run "$repo")
[ "$(val RELEASE_MODEL "$o")" = "release-triggered" ] \
  || fail "a manual hatch on a release-triggered workflow must not flip the model: $(val RELEASE_MODEL "$o")"
[ -n "$(val RELEASE_NOTES_BASELINE "$o")" ] \
  || fail "still release-triggered, so the notes baseline stands: $o"
rm -f "$(val RELEASE_NOTES_BASELINE "$o")"
ok "release: with a workflow_dispatch hatch stays release-triggered"

# --- a repo that states its publish path --------------------------------------
# The repo is the authority; naming the doc is deterministic, reading it is not.
repo=$(new_repo states-publish)
printf '{\n  "name": "x",\n  "version": "1.0.0"\n}\n' > "$repo/package.json"
printf '# p\n\nReleases are cut by the maintainer, who runs make ship.\n' > "$repo/AGENTS.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m states
o=$(run "$repo")
[ "$(val RELEASE_PUBLISH_DOCS "$o")" = "AGENTS.md" ] \
  || fail "a doc stating how the repo publishes should be named: $(val RELEASE_PUBLISH_DOCS "$o")"
ok "a stated publish path is surfaced for the skill to read"

repo=$(new_repo silent-docs)
printf '{\n  "name": "x",\n  "version": "1.0.0"\n}\n' > "$repo/package.json"
printf '# p\n\nRun the tests with make test.\n' > "$repo/AGENTS.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m silent
o=$(run "$repo")
[ -z "$(val RELEASE_PUBLISH_DOCS "$o")" ] \
  || fail "a doc saying nothing about publishing should not be named: $o"
ok "a repo whose docs say nothing about publishing surfaces none"

# The statement can end the line — prose wraps, and requiring whitespace after
# `are` is how the phrase most people write goes undetected.
repo=$(new_repo wrapped-statement)
printf '{\n  "name": "x",\n  "version": "1.0.0"\n}\n' > "$repo/package.json"
printf '# p\n\nReleases are\ncut by the maintainer.\n' > "$repo/AGENTS.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m wrapped
o=$(run "$repo")
[ "$(val RELEASE_PUBLISH_DOCS "$o")" = "AGENTS.md" ] \
  || fail "a statement wrapping at end of line should still be found: $o"
ok "a publish statement broken across lines is still surfaced"

# --- branch + push state ------------------------------------------------------
[ "$(val RELEASE_BRANCH "$o")" = "main" ] || fail "branch wrong: $o"
[ "$(val RELEASE_ON_DEFAULT "$o")" = "1" ] || fail "main is the default branch here: $o"
[ -z "$(val RELEASE_UPSTREAM "$o")" ] || fail "no remote configured, so no upstream: $o"
ok "branch, default-branch, and upstream state reported"

# --- an unrecognized target is an error, not a silent cwd read ----------------
if bash "$recon" --repo "$work/nope" 2>/dev/null; then
  fail "a non-repo target should exit non-zero rather than read the cwd repo"
fi
ok "non-repo --repo target -> non-zero"

echo "# all checks passed"
