#!/usr/bin/env bash
# Run /anchor:release's publish step: create the forge release, or dispatch the
# release workflow.
#
# Why a script (not skill prose): both are the irreversible half of a release,
# and hooks/route-to-skill.sh denies them as raw `gh` / `glab` calls so a session
# can't reach them around the skill. This is the route it leaves open. Whether to
# publish, and at what level, is the author's call and stays in the skill, which
# confirms it before calling this.
#
# No pass-through arguments: the notes go by file, and nothing here can add
# `--generate-notes` (RELEASE-14).
#
# Output lines (KEY=value, read from stdout):
#   RESOLVED_VIA=<repo|cwd>
#   FORGE=<github|gitlab>
#   PUBLISHED=<release|dispatch>
#   RELEASE_URL=<url>        --release: read back from the forge
#   RELEASE_TAG=<tag>        --release
#   RUN_URL=<url>            --dispatch: the run gh reported, empty when it
#                            printed none (find it with `gh run list --workflow`)
#
# On a failure it prints PUBLISH_ERROR=<message> and exits non-zero: 64 a usage
# error, 69 a path this forge has no equivalent for, 70 a forge failure.
#
# Usage:
#   release-publish.sh --release <tag> --notes-file <path> [--title <t>] [--target <full-sha|branch>]
#   release-publish.sh --dispatch <workflow> --input <name>=<value> [--input ...] [--ref <ref>]
#   ... [--repo <checkout>]

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"

die() { echo "PUBLISH_ERROR=$2"; exit "$1"; }

CTX_REPO=""
mode=""
tag=""
notes=""
title=""
target=""
workflow=""
ref=""
inputs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)    mode=release;  tag="${2:-}";      shift 2 || die 64 "--release needs a tag" ;;
    --dispatch)   mode=dispatch; workflow="${2:-}"; shift 2 || die 64 "--dispatch needs a workflow" ;;
    --notes-file) notes="${2:-}";  shift 2 || die 64 "--notes-file needs a path" ;;
    --title)      title="${2:-}";  shift 2 || die 64 "--title needs text" ;;
    --target)     target="${2:-}"; shift 2 || die 64 "--target needs a ref" ;;
    --ref)        ref="${2:-}";    shift 2 || die 64 "--ref needs a ref" ;;
    --input)
      [[ "${2:-}" == ?*=* ]] || die 64 "--input takes <name>=<value>"
      inputs+=("$2"); shift 2 ;;
    --repo)
      [[ -n "${2:-}" ]] || die 64 "--repo needs a path"
      CTX_REPO="$2"; shift 2 ;;
    *) die 64 "unrecognized argument: $1" ;;
  esac
done

case "$mode" in
  release)
    [[ -n "$tag" ]] || die 64 "--release needs a tag"
    [[ -n "$notes" && -s "$notes" ]] || die 64 "--notes-file must name a non-empty file"
    ;;
  dispatch)
    [[ -n "$workflow" ]] || die 64 "--dispatch needs a workflow"
    [[ ${#inputs[@]} -gt 0 ]] || die 64 "--dispatch needs the level as --input <name>=<value>"
    ;;
  *) die 64 "pass --release <tag> or --dispatch <workflow>" ;;
esac

# Resolve the notes path before any cd, so a relative one still names the file.
if [[ -n "$notes" && "$notes" != /* ]]; then
  notes="$PWD/$notes"
fi

ctx_resolve_repo
echo "RESOLVED_VIA=$RESOLVED_VIA"

forge=$(anchor_forge_of_origin)
[[ "$forge" != none ]] || die 69 "origin is neither GitHub nor GitLab"
echo "FORGE=$forge"

if [[ "$mode" == release ]]; then
  args=(release create "$tag" --notes-file "$notes")
  case "$forge" in
    github)
      args+=(--title "${title:-$tag}")
      [[ -z "$target" ]] || args+=(--target "$target")
      out=$(gh "${args[@]}" 2>&1) || die 70 "gh release create failed: ${out//$'\n'/ }"
      url=$(gh release view "$tag" --json url -q .url 2>/dev/null || true)
      ;;
    gitlab)
      [[ -z "$title" ]] || args+=(--name "$title")
      [[ -z "$target" ]] || args+=(--ref "$target")
      out=$(glab "${args[@]}" 2>&1) || die 70 "glab release create failed: ${out//$'\n'/ }"
      # GitLab's release object carries no `url`; the web address is _links.self.
      url=$(glab release view "$tag" -F json 2>/dev/null | jq -r '._links.self // empty' 2>/dev/null || true)
      ;;
  esac
  echo "PUBLISHED=release"
  echo "RELEASE_TAG=$tag"
  echo "RELEASE_URL=$url"
  exit 0
fi

# --dispatch
[[ "$forge" == github ]] \
  || die 69 "GitLab has no workflow dispatch; a repo that publishes by a manual pipeline documents its own path"

args=(workflow run "$workflow")
[[ -z "$ref" ]] || args+=(--ref "$ref")
for kv in "${inputs[@]}"; do
  args+=(-f "$kv")
done
out=$(gh "${args[@]}" 2>&1) || die 70 "gh workflow run failed: ${out//$'\n'/ }"

run_url=$(grep -Eo 'https://[^[:space:]]+/actions/runs/[0-9]+' <<<"$out" | head -1 || true)
echo "PUBLISHED=dispatch"
echo "RUN_URL=$run_url"
