#!/usr/bin/env bash
# Watch the pipeline a push just triggered, once per commit, unless the caller's
# skill has been configured out of it. This is the gate in front of
# pipeline-status.sh --watch that the push-side skills (commit, resolve-feedback,
# prepare-review) call — not a second implementation of the watch.
#
# Why a gate at all: a push is what starts CI, so the skill that pushed is the
# one holding the answer to "did it go green". Two things make an automatic
# watch wrong to run unconditionally, and both are decisions rather than
# judgment calls, which is why they live here rather than in skill prose:
#
#   1. Some pushes shouldn't be waited on — a long pipeline, or a skill whose
#      report the user finds noisy. Hence the config keys.
#   2. Consecutive skills often act on the *same* commit: commit pushes and
#      watches, then prepare-review opens a CR on that very sha. Reporting the
#      same pipeline twice is noise, so a run is reported once per repo.
#
# Config, most specific first (both booleans, default true):
#   anchor.<skill>.watchPipelineAfterPush   this skill only
#   anchor.watchPipelineAfterPush           every push-side skill
#
# Output lines (KEY=value, read from stdout):
#   PIPELINE_WATCH=ran|skipped
#   PIPELINE_WATCH_REASON=<why>   (skipped only) `config-off` — a config key
#                                 turned it off; `already-reported` — every run
#                                 for this commit has been reported already
#   …then, when it ran, every line pipeline-status.sh emits, unchanged.
#
# Usage:
#   pipeline-after-push.sh --skill commit
#   pipeline-after-push.sh --skill prepare-review --sha <sha> --timeout 600
#
# --repo / --worktree <path> retargets onto a checkout other than the cwd repo
# (see scripts/lib/resolve-context.sh); --sha, --branch, --workflow, --interval
# and --timeout pass through to pipeline-status.sh.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/resolve-context.sh
source "$here/lib/resolve-context.sh"

skill=""
sha=""
CTX_REPO=""
CTX_WORKTREE=""
passthrough=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill)    skill="${2:?--skill needs a name}"; shift 2 ;;
    --repo)     CTX_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --worktree) CTX_WORKTREE="${2:?--worktree needs a path}"; shift 2 ;;
    --sha)      sha="${2:?--sha needs a value}"; shift 2 ;;
    --branch|--workflow|--interval|--timeout)
                passthrough+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    *) echo "pipeline-after-push.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$skill" ]] || { echo "pipeline-after-push.sh: --skill <name> is required" >&2; exit 64; }

ctx_resolve_repo

[[ -n "$sha" ]] || sha=$(git rev-parse HEAD)

# git's own boolean parsing, so `false`/`no`/`0`/`off` all mean off. An unset
# key leaves $enabled empty and the default (on) stands.
config_bool() {
  git config --type=bool --get "$1" 2>/dev/null || true
}

enabled=$(config_bool "anchor.${skill}.watchPipelineAfterPush")
[[ -n "$enabled" ]] || enabled=$(config_bool "anchor.watchPipelineAfterPush")
if [[ "$enabled" == "false" ]]; then
  echo "PIPELINE_WATCH=skipped"
  echo "PIPELINE_WATCH_REASON=config-off"
  exit 0
fi

# The ledger of reported runs lives in the *common* git dir, so every worktree of
# a repo shares it — a flow that pushes from an isolated worktree and reports
# from the main checkout is still one report.
#
# It holds run ids, not commit shas. A sha is the wrong key: where CI is gated on
# the CR rather than the push (`on: pull_request`), the push-time watch correctly
# finds no pipeline, and a sha-keyed ledger would then swallow the *first* report
# of the pipeline that opening the CR actually starts.
ledger="$(git rev-parse --git-common-dir)/anchor/pipeline-reported"

# `${a[@]+…}` because macOS still ships bash 3.2, where expanding an empty array
# under `set -u` is an unbound-variable error.
status() {
  bash "$here/pipeline-status.sh" --sha "$sha" \
    ${passthrough[@]+"${passthrough[@]}"} "$@"
}

run_ids() {
  sed -n 's/^PIPELINE_RUNS=//p' <<<"$1" | jq -r '.[].id' 2>/dev/null || true
}

# A one-shot read first, to answer "have these runs been reported?" before
# spending a watch on them. No runs yet (or no pipeline at all) is not a match —
# there is nothing to have reported.
ids=$(run_ids "$(status)")
if [[ -n "$ids" ]] && [[ -f "$ledger" ]]; then
  unseen=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    grep -qxF "$id" "$ledger" || { unseen=1; break; }
  done <<<"$ids"
  if [[ "$unseen" == "0" ]]; then
    echo "PIPELINE_WATCH=skipped"
    echo "PIPELINE_WATCH_REASON=already-reported"
    exit 0
  fi
fi

echo "PIPELINE_WATCH=ran"
out=$(status --watch)
printf '%s\n' "$out"

# Recorded from the settled result, so a run only counts as reported once it has
# actually been reported.
settled=$(run_ids "$out")
if [[ -n "$settled" ]]; then
  mkdir -p "$(dirname "$ledger")"
  printf '%s\n' "$settled" >> "$ledger"
  # Bounded so a long-lived clone's ledger stays small; the tail is what a
  # follow-up on the same commit could still be checking against.
  if [[ $(wc -l < "$ledger") -gt 200 ]]; then
    tail -n 100 "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
  fi
fi
