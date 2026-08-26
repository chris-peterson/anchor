#!/usr/bin/env bash
# Gather the facts a release decision rests on, in one pass, so the skill spends
# its turn on judgment (which version, what the notes say) rather than on shell
# archaeology. Prints a KEY=value block on stdout.
#
# The load-bearing output is RELEASE_MODEL: who owns the version bump. Getting it
# wrong is the expensive mistake in a release — hand-editing a manifest whose CI
# workflow also bumps it lands two conflicting commits, and the collision only
# shows up after the release is already published.
#
# Why a script (not skill prose): every fact here is a deterministic read of the
# tree, the git history, and the CI config. Detecting the model by grep is also
# the part a prompt gets subtly wrong — `jobs:\n  release:` and
# `on:\n  release:` are the same two-space-indented `release:` line, so the
# distinction needs a real look at which block it sits in, not a pattern match.
#
# Output lines (KEY=value, read from stdout):
#   RELEASE_MODEL=<model>              who owns the bump — see the table below
#   RELEASE_FORGE=<github|gitlab|none>
#   RELEASE_WORKFLOW=<path>            the release/tag-triggered CI file (model's evidence)
#   RELEASE_MANIFEST=<path>            the shipped version manifest (empty: none found)
#   RELEASE_MANIFEST_SOURCE=<path>     the canonical descriptor when the manifest is
#                                      generated from one — bump THIS, not the manifest
#   RELEASE_MANIFEST_REGEN=<cmd>       the command that regenerates the manifest
#   RELEASE_VERSION=<x.y.z>            the current version (empty: no manifest)
#   RELEASE_VERSION_BUMPS=<n>          commits that ever changed it — 0 means this repo
#                                      has never versioned, so bumping is a convention
#                                      decision for the author, not a mechanical step
#   RELEASE_BUMP_CONVENTION=<fold|standalone|mixed|none>
#                                      do prior bumps stand alone or ride the feature commit
#   RELEASE_LAST_REF=<ref>             what the last release shipped as
#   RELEASE_LAST_REF_KIND=<tag|bump-commit|root>
#   RELEASE_RANGE=<ref>..HEAD          the commit range that is shipping
#   RELEASE_COMMITS=<n>                commits in that range
#   RELEASE_CHANGELOG=<path>           (empty: none)
#   RELEASE_CHANGELOG_HAS_CURRENT=<0|1>  a section for RELEASE_VERSION already exists,
#                                      i.e. the current version looks already shipped
#   RELEASE_CHANGELOG_UNRELEASED=<0|1>   an Unreleased section is accruing notes
#   RELEASE_BRANCH=<branch>
#   RELEASE_DEFAULT_BRANCH=<branch>
#   RELEASE_ON_DEFAULT=<0|1>
#   RELEASE_UPSTREAM=<ref>             tracking branch (empty: none)
#   RELEASE_UNPUSHED=<n>               commits ahead of upstream
#   RELEASE_DIRTY=<0|1>                uncommitted changes present
#   RELEASE_NOTES_PATH=<path>          a unique path to write the drafted notes to
#                                      (not created — the caller writes it)
#   RELEASE_NOTES_BASELINE=<path>      an empty file, the left-hand side of the notes
#                                      review; only for the models that publish the
#                                      notes as a release body, empty otherwise
#   RESOLVED_VIA=<repo|cwd>
#
# Models, in detection precedence — the first that matches wins:
#   release-triggered    CI fires on a published release and owns the bump. Publish
#                        with `gh release create`; never hand-edit the manifest.
#   tag-triggered        CI fires on a tag push and owns the publish.
#   bump-commit          no release CI; a version manifest exists, so the bump is a
#                        commit in this repo.
#   no-version-artifact  no manifest at all (IaC, docs, a content repo) — the merge
#                        already was the release.
#
# Modes:
#   release-recon.sh                    the cwd repo
#   release-recon.sh --repo <path>      a checkout other than the cwd repo

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

CTX_REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) echo "release-recon.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

ctx_resolve_repo

detect_forge() {
  local url
  url=$(git remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) echo "github" ;;
    *gitlab*)     echo "gitlab" ;;
    *)            echo "" ;;
  esac
}

# Read a version out of a manifest's *content* (stdin), dispatching on the path's
# shape. Emits nothing when the file carries no version it recognizes, so a
# caller distinguishes "no version here" from a value.
extract_version() {
  local path="$1" base
  base=$(basename "$path")
  case "$base" in
    *.json)
      jq -r '.version // empty' 2>/dev/null || true ;;
    *.yml|*.yaml)
      sed -n 's/^version:[[:space:]]*["'\'']\{0,1\}\([^"'\''[:space:]]\{1,\}\).*/\1/p' | head -1 ;;
    *.toml)
      sed -n 's/^version[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\).*/\1/p' | head -1 ;;
    *.psd1)
      sed -n 's/.*ModuleVersion[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\).*/\1/p' | head -1 ;;
    *.csproj)
      sed -n 's|.*<Version>\([^<]*\)</Version>.*|\1|p' | head -1 ;;
    setup.cfg)
      sed -n 's/^version[[:space:]]*=[[:space:]]*\(.*\)/\1/p' | head -1 | tr -d '[:space:]' ;;
    VERSION|version.txt)
      head -1 | tr -d '[:space:]' ;;
    *) true ;;
  esac
}

version_in_tree() {
  local path="$1" content
  [[ -f "$path" ]] || return 0
  content=$(<"$path")
  extract_version "$path" <<<"$content"
}

version_at_ref() {
  local ref="$1" path="$2" content
  content=$(git show "$ref:$path" 2>/dev/null) || return 0
  extract_version "$path" <<<"$content"
}

# --- The version manifest -----------------------------------------------------
# First match wins. A Claude plugin manifest outranks an auxiliary package.json:
# Claude Code keys plugin updates off its version, so it is the one that ships.
find_manifest() {
  local c
  for c in .claude-plugin/plugin.json package.json pyproject.toml Cargo.toml \
           setup.cfg VERSION version.txt; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done
  for c in ./*.psd1 ./*.csproj; do
    [[ -f "$c" ]] && { echo "${c#./}"; return; }
  done
}

# A manifest can be *generated* from a canonical descriptor, in which case
# editing the manifest drifts it from its source and a sync check rejects the
# commit. Treat a root descriptor carrying its own `version:` as that source.
find_manifest_source() {
  local manifest="$1" c
  [[ "$manifest" == ".claude-plugin/plugin.json" ]] || return 0
  for c in plugin.yml plugin.yaml; do
    [[ -f "$c" ]] || continue
    [[ -n "$(version_in_tree "$c")" ]] && { echo "$c"; return; }
  done
}

# The regeneration command, when a justfile recipe runs one. Matching on the
# recipe body (not its name) is what makes this work across naming choices.
find_regen_cmd() {
  [[ -f justfile ]] || return 0
  awk '
    /^[a-zA-Z0-9_-]+:/ { recipe = $0; sub(/:.*/, "", recipe); next }
    /^[[:space:]]+/ && recipe != "" && /plugin-json/ { print "just " recipe; exit }
  ' justfile
}

manifest=$(find_manifest || true)
manifest_source=""
regen_cmd=""
version=""
if [[ -n "$manifest" ]]; then
  manifest_source=$(find_manifest_source "$manifest" || true)
  regen_cmd=$(find_regen_cmd || true)
  # The source is the version of record when one exists — it is what a bump edits.
  version=$(version_in_tree "${manifest_source:-$manifest}")
fi

# --- The release model --------------------------------------------------------
# Which block a `release:` line sits in decides the model, and `jobs:` blocks
# hold `release:` job names at the same indent as `on:` blocks hold the trigger.
# So walk the top-level keys and only look inside `on:`.
workflow_trigger() {
  awk '
    # A top-level key (column 0, not a comment) opens a new block.
    /^[^[:space:]#]/ { on_block = ($0 ~ /^("on"|'"'"'on'"'"'|on)[[:space:]]*:/); next }
    !on_block { next }
    /^[[:space:]]+release[[:space:]]*:/ { print "release"; exit }
    /^[[:space:]]+tags([[:space:]]*:|-ignore)/ { print "tags"; exit }
  ' "$1"
}

detect_ci_model() {
  local f trigger tag_workflow=""
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -f "$f" ]] || continue
    trigger=$(workflow_trigger "$f")
    case "$trigger" in
      release) echo "release-triggered $f"; return ;;
      tags)    [[ -n "$tag_workflow" ]] || tag_workflow="$f" ;;
    esac
  done
  if [[ -n "$tag_workflow" ]]; then
    echo "tag-triggered $tag_workflow"
    return
  fi
  # GitLab has no release-published event; a tag-gated pipeline is the shape.
  if [[ -f .gitlab-ci.yml ]] && grep -q 'CI_COMMIT_TAG' .gitlab-ci.yml; then
    echo "tag-triggered .gitlab-ci.yml"
  fi
}

read -r ci_model workflow <<<"$(detect_ci_model || true)"
ci_model="${ci_model:-}"
workflow="${workflow:-}"

if [[ -n "$ci_model" ]]; then
  model="$ci_model"
elif [[ -n "$manifest" ]]; then
  model="bump-commit"
else
  model="no-version-artifact"
fi

# --- Version history: has this repo ever bumped, and how does it commit it? ---
# Walk the commits that touched the version file, newest first, and keep the ones
# where the value actually moved — a commit can touch the manifest without
# bumping it. The newest such commit is the de facto last release when no tag
# anchors one.
version_file="${manifest_source:-$manifest}"
bump_count=0
bump_commit=""
fold=0
standalone=0

if [[ -n "$version_file" ]]; then
  while read -r sha; do
    [[ -n "$sha" ]] || continue
    at=$(version_at_ref "$sha" "$version_file")
    before=$(version_at_ref "$sha^" "$version_file" 2>/dev/null || true)
    [[ "$at" == "$before" ]] && continue
    bump_count=$(( bump_count + 1 ))
    [[ -n "$bump_commit" ]] || bump_commit="$sha"

    # Bookkeeping-only means the bump stood alone; anything else means it rode
    # along with real work.
    others=$(git show --name-only --format= "$sha" | grep -vE \
      "^($version_file|$manifest|CHANGELOG(\.md)?|STATUS\.md|docs/|.*\.lock|package-lock\.json)$" || true)
    if [[ -z "$others" ]]; then
      standalone=$(( standalone + 1 ))
    else
      fold=$(( fold + 1 ))
    fi
  done < <(git log --format=%H -n 40 -- "$version_file" 2>/dev/null || true)
fi

if   (( standalone > 0 && fold > 0 )); then convention="mixed"
elif (( standalone > 0 ));            then convention="standalone"
elif (( fold > 0 ));                  then convention="fold"
else                                       convention="none"
fi

# --- What is shipping ---------------------------------------------------------
latest_tag=$(git tag --list --sort=-v:refname 2>/dev/null \
             | grep -E '^v?[0-9]+\.[0-9]+' | head -1 || true)
if [[ -n "$latest_tag" ]]; then
  last_ref="$latest_tag"; last_kind="tag"
elif [[ -n "$bump_commit" ]]; then
  last_ref="$bump_commit"; last_kind="bump-commit"
else
  last_ref=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1 || true)
  last_kind="root"
fi

commits=0
[[ -n "$last_ref" ]] && commits=$(git rev-list --count "$last_ref..HEAD" 2>/dev/null || echo 0)

changelog=""
for c in CHANGELOG.md CHANGELOG; do
  [[ -f "$c" ]] && { changelog="$c"; break; }
done
has_current=0
unreleased=0
if [[ -n "$changelog" ]]; then
  if [[ -n "$version" ]] \
     && grep -qE "^#+[[:space:]]*\[?v?${version//./\\.}\]?([[:space:]]|$|\])" "$changelog"; then
    has_current=1
  fi
  grep -qiE '^#+[[:space:]]*\[?unreleased' "$changelog" && unreleased=1
fi

branch=$(git rev-parse --abbrev-ref HEAD)
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
                 | sed 's@^refs/remotes/origin/@@' || true)
if [[ -z "$default_branch" ]]; then
  for c in main master; do
    git show-ref --verify --quiet "refs/heads/$c" && { default_branch="$c"; break; }
  done
fi
on_default=0
[[ "$branch" == "$default_branch" ]] && on_default=1

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
unpushed=0
[[ -n "$upstream" ]] && unpushed=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)

dirty=0
[[ -n "$(git status --porcelain)" ]] && dirty=1

# Notes paths, supplied here so the skill reads them rather than minting its own.
# The baseline is the left-hand side of the notes review, which only the models
# that publish the notes as a release body run — on bump-commit the notes are
# reviewed as part of the commit instead.
notes_path=$(anchor_tmpfile release-notes)
notes_baseline=""
case "$model" in
  release-triggered|tag-triggered)
    notes_baseline=$(anchor_tmpfile release-notes-baseline)
    : > "$notes_baseline"
    ;;
esac

echo "RELEASE_MODEL=$model"
echo "RELEASE_FORGE=$(detect_forge || true)"
echo "RELEASE_WORKFLOW=$workflow"
echo "RELEASE_MANIFEST=$manifest"
echo "RELEASE_MANIFEST_SOURCE=$manifest_source"
echo "RELEASE_MANIFEST_REGEN=$regen_cmd"
echo "RELEASE_VERSION=$version"
echo "RELEASE_VERSION_BUMPS=$bump_count"
echo "RELEASE_BUMP_CONVENTION=$convention"
echo "RELEASE_LAST_REF=$last_ref"
echo "RELEASE_LAST_REF_KIND=$last_kind"
echo "RELEASE_RANGE=$last_ref..HEAD"
echo "RELEASE_COMMITS=$commits"
echo "RELEASE_CHANGELOG=$changelog"
echo "RELEASE_CHANGELOG_HAS_CURRENT=$has_current"
echo "RELEASE_CHANGELOG_UNRELEASED=$unreleased"
echo "RELEASE_BRANCH=$branch"
echo "RELEASE_DEFAULT_BRANCH=$default_branch"
echo "RELEASE_ON_DEFAULT=$on_default"
echo "RELEASE_UPSTREAM=$upstream"
echo "RELEASE_UNPUSHED=$unpushed"
echo "RELEASE_DIRTY=$dirty"
echo "RELEASE_NOTES_PATH=$notes_path"
echo "RELEASE_NOTES_BASELINE=$notes_baseline"
echo "RESOLVED_VIA=$RESOLVED_VIA"
