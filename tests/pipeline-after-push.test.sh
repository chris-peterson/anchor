#!/usr/bin/env bash
# Functional test for scripts/pipeline-after-push.sh — the gate the push-side
# skills call instead of watching CI unconditionally.
#
# The two things worth pinning are the two reasons an automatic watch is wrong
# to run: a skill configured out of it, and a run that was already reported by
# the skill that pushed it.
#
# The load-bearing case is the second one's boundary. Where CI is gated on the CR
# (`on: pull_request`), the push-time watch finds no pipeline — and the pipeline
# that opening the CR then starts is the *first* one anyone has seen, not a
# duplicate. Keying the ledger on the commit swallowed exactly that report, so
# the fixtures below walk that sequence: no runs, then runs.
set -euo pipefail

# Hermetic: ignore the user's global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/../scripts/pipeline-after-push.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-after-push-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- stub gh: serves $GH_RUNS (workflow runs for a sha) and $GH_JOBS (a run's
# jobs), the same two lookups pipeline-status.sh makes.
bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  api)  jq -c '{total_count: length, workflow_runs: .}' "$GH_RUNS" ;;
  run)  jq -c '{jobs: .}' "$GH_JOBS" ;;
  *)    echo "stub gh: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh"
export PATH="$bin:$PATH"

no_runs()  { printf '[]' > "$work/runs.json"; }
one_run()  {
  cat > "$work/runs.json" <<JSON
[ { "id": $1, "name": "Test", "path": ".github/workflows/test.yml",
    "head_branch": "main", "head_sha": "$2",
    "status": "completed", "conclusion": "success",
    "created_at": "2026-08-05T12:00:00Z",
    "html_url": "https://github.com/acme/widget/actions/runs/$1" } ]
JSON
}
printf '[ { "name": "unit", "status": "completed", "conclusion": "success",
            "url": "https://github.com/acme/widget/actions/runs/1/job/1" } ]' > "$work/jobs.json"
export GH_RUNS="$work/runs.json" GH_JOBS="$work/jobs.json"

repo="$work/widget"
git init --quiet -b main "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
git -C "$repo" config commit.gpgsign false
printf 'seed\n' > "$repo/README.md"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m seed
git -C "$repo" remote add origin "https://github.com/acme/widget.git"
sha=$(git -C "$repo" rev-parse HEAD)
ledger="$repo/.git/anchor/pipeline-reported"
# Every watch below settles on its first poll, so no test ever sleeps.
export PIPELINE_APPEAR_TIMEOUT=0

gate_run() { bash "$gate" --repo "$repo" "$@"; }
forget()   { rm -f "$ledger"; }
unset_keys() {
  git -C "$repo" config --unset-all anchor.watchPipelineAfterPush 2>/dev/null || true
  git -C "$repo" config --unset-all anchor.commit.watchPipelineAfterPush 2>/dev/null || true
}

# ===================== unset config means the watch runs =====================
one_run 4001 "$sha"
o=$(gate_run --skill commit)
[ "$(val PIPELINE_WATCH "$o")" = "ran" ] \
  || fail "with no config the watch is on — that's the point of the feature: $o"
[ "$(val PIPELINE_STATE "$o")" = "success" ] \
  || fail "the watch's own output should follow the gate's line: $o"
ok "an unconfigured repo watches after a push"

[ -f "$ledger" ] || fail "a reported run should be recorded under .git/anchor"
grep -qxF 4001 "$ledger" || fail "the ledger should name the run just reported"
ok "the reported run is recorded in the repo's ledger"

# ===================== the same run is reported once =========================
o=$(gate_run --skill prepare-review)
[ "$(val PIPELINE_WATCH "$o")" = "skipped" ] \
  || fail "a run already reported must not be watched again: $o"
[ "$(val PIPELINE_WATCH_REASON "$o")" = "already-reported" ] \
  || fail "expected the dedupe reason: $o"
ok "a CR opened on an already-reported run doesn't report it twice"

# ===================== CR-gated CI: the first report isn't a duplicate =======
# The regression this pins: `on: pull_request` means the push-time watch finds
# nothing, and the run that opening the CR starts is the first anyone has seen.
forget
no_runs
o=$(gate_run --skill commit)
[ "$(val PIPELINE_STATE "$o")" = "none" ] || fail "a push that starts nothing is none: $o"
[ -f "$ledger" ] && fail "reporting no pipeline records nothing — there was no run to report"
ok "a push that triggers no pipeline leaves the ledger empty"

one_run 4002 "$sha"
o=$(gate_run --skill prepare-review)
[ "$(val PIPELINE_WATCH "$o")" = "ran" ] \
  || fail "the run that opening the CR started has never been reported: $o"
[ "$(val PIPELINE_ID "$o")" = "4002" ] || fail "expected the CR-triggered run: $o"
ok "a CR-triggered pipeline is reported even though the push reported none"

# A run the ledger hasn't seen re-arms the gate, even on the same commit — a
# re-run, or a second workflow, is a pipeline nobody has looked at.
one_run 4003 "$sha"
o=$(gate_run --skill prepare-review)
[ "$(val PIPELINE_WATCH "$o")" = "ran" ] || fail "an unseen run is reported: $o"
ok "an unseen run on an already-reported commit is still reported"

# ===================== the config keys turn it off ===========================
forget; unset_keys
git -C "$repo" config anchor.watchPipelineAfterPush false
o=$(gate_run --skill commit)
[ "$(val PIPELINE_WATCH "$o")" = "skipped" ] || fail "the umbrella key should turn it off: $o"
[ "$(val PIPELINE_WATCH_REASON "$o")" = "config-off" ] || fail "expected the config reason: $o"
[ -f "$ledger" ] && fail "a skipped watch reports nothing, so it records nothing"
ok "anchor.watchPipelineAfterPush false turns the watch off"

# Per-skill wins over the umbrella in both directions — the point is being able
# to keep it for the commit you just made while dropping it for a CR open.
git -C "$repo" config anchor.commit.watchPipelineAfterPush true
o=$(gate_run --skill commit)
[ "$(val PIPELINE_WATCH "$o")" = "ran" ] \
  || fail "a per-skill true should override the umbrella false: $o"
ok "anchor.<skill>.watchPipelineAfterPush overrides the umbrella key"

forget; unset_keys
git -C "$repo" config anchor.prepare-review.watchPipelineAfterPush false
o=$(gate_run --skill commit)
[ "$(val PIPELINE_WATCH "$o")" = "ran" ] \
  || fail "another skill's key must not silence this one: $o"
forget
o=$(gate_run --skill prepare-review)
[ "$(val PIPELINE_WATCH "$o")" = "skipped" ] \
  || fail "the named skill's key should turn that skill off: $o"
ok "a per-skill key silences only the skill it names"

# ===================== a missing --skill is an error =========================
if bash "$gate" --repo "$repo" >/dev/null 2>&1; then
  fail "--skill decides which config key applies, so it can't be optional"
fi
ok "--skill is required"

echo "all pipeline-after-push tests passed"
