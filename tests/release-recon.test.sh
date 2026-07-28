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
