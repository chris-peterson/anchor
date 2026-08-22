#!/usr/bin/env bash
# Functional test for the CLI entrypoint (scripts/anchor).
#
# Covers the surface contract a caller depends on — one JSON object on stdout and
# nothing else, diagnostics on stderr, exit codes that say whether the command
# ran — plus the completion parity guard and the install-cli side effects, which
# run against a scratch HOME rather than the real one.
#
# The diff case drives the real dispatcher against a stub revdiff launcher, the
# same seam tests/review-diff.test.sh uses. Requires jq.
set -euo pipefail

# Hermetic: the user's global anchor.reviewBackend must not pick the backend.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
cli="$root/scripts/anchor"

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-cli-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- version, help, and the no-args contract ---------------------------------

manifest_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$root/.claude-plugin/plugin.json" | head -1)
[ -n "$manifest_version" ] || fail "could not read the version from the plugin manifest"

reported=$(bash "$cli" --version)
[ "$reported" = "anchor $manifest_version" ] \
  || fail "--version said '$reported', manifest says '$manifest_version'"
ok "--version matches .claude-plugin/plugin.json"

for flag in help --help -h; do
  # set -e already fails the suite on a non-zero exit here.
  out=$(bash "$cli" "$flag" 2>"$work/err")
  [ -n "$out" ] || fail "$flag printed nothing to stdout"
  [ ! -s "$work/err" ] || fail "$flag wrote to stderr: $(cat "$work/err")"
done
ok "help / --help / -h print usage on stdout and exit 0"

set +e
out=$(bash "$cli" 2>"$work/err"); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "no-args exited $rc, want 64"
[ -z "$out" ] || fail "no-args wrote to stdout: $out"
grep -q 'usage: anchor' "$work/err" || fail "no-args did not print usage on stderr"
ok "no-args prints usage on stderr and exits 64"

set +e
out=$(bash "$cli" not-a-command 2>"$work/err"); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "unknown command exited $rc, want 64"
[ -z "$out" ] || fail "unknown command wrote to stdout: $out"
grep -q 'unknown command: not-a-command' "$work/err" \
  || fail "unknown command did not name itself on stderr"
ok "an unknown command exits 64 and names itself on stderr"

# --- completion parity -------------------------------------------------------
#
# One source (the ANCHOR_COMMANDS array) feeds dispatch, the usage text, and the
# completion, so this asserts the three agree rather than policing three lists.
# Missing (dispatched but unoffered) and stale (offered but undispatched) are both
# drift, so these are equality checks, and the non-empty assertion keeps a parse
# that matches nothing from passing by comparing two empty sets.

declared=$(sed -n '/^ANCHOR_COMMANDS=(/,/^)/p' "$cli" \
  | sed -n 's/^[[:space:]]*"\([a-z-]*\):.*/\1/p' | sort)
[ -n "$declared" ] || fail "parsed no commands out of ANCHOR_COMMANDS — the parse is broken, not the CLI"

offered=$(bash "$cli" completions zsh | sed -n "s/^[[:space:]]*'\([a-z-]*\):.*/\1/p" | sort)
[ -n "$offered" ] || fail "the generated completion offered no commands"

[ "$declared" = "$offered" ] || fail "completion parity: declared [$(echo "$declared" | tr '\n' ' ')] vs offered [$(echo "$offered" | tr '\n' ' ')]"
ok "every declared command is offered by the completion, and vice versa ($(echo "$declared" | tr '\n' ' '))"

# Each declared command must resolve to a handler, or dispatch calls a function
# that does not exist and bash reports "command not found" as the CLI's error.
while IFS= read -r name; do
  handler="cmd_${name//-/_}"
  grep -q "^${handler}()" "$cli" || fail "no handler ${handler}() for declared command '$name'"
done <<<"$declared"
ok "every declared command has a cmd_* handler"

head -1 <(bash "$cli" completions zsh) | grep -qx '#compdef anchor' \
  || fail "the completion is missing its '#compdef anchor' first line"
ok "the completion carries the #compdef header its _anchor filename needs"

set +e
bash "$cli" completions bash >/dev/null 2>"$work/err"; rc=$?
set -e
[ "$rc" -eq 64 ] || fail "completions for an unsupported shell exited $rc, want 64"
ok "completions refuses a shell it has no script for"

# --- diff --------------------------------------------------------------------

printf 'alpha\n' > "$work/left.md"
printf 'beta\n'  > "$work/right.md"

cat > "$work/stub-launcher.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$STUB_ARGS_FILE"
if [ -n "${STUB_DESC_CAPTURE:-}" ]; then
  for arg in "$@"; do
    case "$arg" in --description-file=*) cp "${arg#*=}" "$STUB_DESC_CAPTURE" ;; esac
  done
fi
printf '%s' "${STUB_OUTPUT:-}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$work/stub-launcher.sh"
export ANCHOR_REVDIFF_LAUNCHER="$work/stub-launcher.sh"
export STUB_ARGS_FILE="$work/args.txt"

set +e
out=$(bash "$cli" diff "$work/left.md" 2>"$work/err"); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "diff with one path exited $rc, want 64"
[ -z "$out" ] || fail "diff usage error wrote to stdout: $out"
ok "diff with fewer than two paths exits 64 with an empty stdout"

# Exported, not prefixed: the stub reads these from the environment two processes
# down, and `VAR=x out=$(...)` would only set a shell variable in this one.
export STUB_OUTPUT='## right.md:1 (+)
this line changed meaning'
export STUB_RC=10
out=$(bash "$cli" diff "$work/left.md" "$work/right.md" 2>"$work/err")

printf '%s' "$out" | jq -e . >/dev/null || fail "diff stdout is not parseable JSON: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] \
  || fail "diff stdout carried more than the one JSON object: $out"
grep -qv 'REVIEW_VERDICT' <<<"$out" || fail "diff leaked the skill-facing REVIEW_VERDICT line onto stdout"
ok "diff prints exactly one JSON object on stdout, with no KEY=value framing"

verdict=$(printf '%s' "$out" | jq -r '.verdict')
[ "$verdict" = "changes-requested" ] || fail "verdict was '$verdict', want changes-requested"
anchored=$(printf '%s' "$out" | jq -r '"\(.comments[0].file):\(.comments[0].startLine)"')
[ "$anchored" = "right.md:1" ] || fail "comment anchored to '$anchored', want right.md:1"
ok "the review contract carries the verdict and the comment's file:line anchor"

grep -q -- "--compare-old=$work/left.md" "$STUB_ARGS_FILE" \
  || fail "the left path did not reach the backend: $(cat "$STUB_ARGS_FILE")"
grep -q -- "--compare-new=$work/right.md" "$STUB_ARGS_FILE" \
  || fail "the right path did not reach the backend: $(cat "$STUB_ARGS_FILE")"
ok "both paths reach the review backend"

export STUB_DESC_CAPTURE="$work/desc.md"
export STUB_RC=0
out=$(bash "$cli" diff "$work/left.md" "$work/right.md" \
  --title "Revised description" --detail "reviewer=you" --detail "budget=5 min" 2>/dev/null)
grep -q 'Revised description' "$STUB_DESC_CAPTURE" || fail "--title did not reach the review header"
grep -q 'reviewer' "$STUB_DESC_CAPTURE" || fail "the first --detail did not reach the review header"
grep -q 'budget' "$STUB_DESC_CAPTURE" || fail "the second --detail did not reach the review header"
ok "--title and repeated --detail seed the review header"
unset STUB_DESC_CAPTURE

set +e
out=$(bash "$cli" diff "$work/left.md" "$work/right.md" --bogus 2>"$work/err"); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "diff with an unknown option exited $rc, want 64"
ok "diff rejects an unknown option"

set +e
out=$(bash "$cli" diff "$work/left.md" "$work/right.md" --detail nokv 2>"$work/err"); rc=$?
set -e
[ "$rc" -eq 64 ] || fail "--detail without label=value exited $rc, want 64"
ok "--detail requires label=value"

# A dispatcher that dies before reporting produces silence, which is
# indistinguishable from a clean review unless the caller treats it as failure
# (SPEC DIFF-12). Point the CLI at a dispatcher that prints nothing.
mkdir -p "$work/hollow/scripts/lib" "$work/hollow/.claude-plugin"
cp "$root/.claude-plugin/plugin.json" "$work/hollow/.claude-plugin/plugin.json"
cp "$cli" "$work/hollow/scripts/anchor"
cp "$root/scripts/lib/plugin-version.sh" "$work/hollow/scripts/lib/plugin-version.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/hollow/scripts/review-diff.sh"
set +e
out=$(CLAUDE_PLUGIN_ROOT="$work/hollow" bash "$work/hollow/scripts/anchor" \
  diff "$work/left.md" "$work/right.md" 2>"$work/err"); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a dispatcher that reported nothing was treated as success"
[ -z "$out" ] || fail "a silent dispatcher still produced stdout: $out"
grep -q 'no verdict' "$work/err" || fail "the silent-dispatcher error did not say no verdict was produced"
ok "silence from the dispatcher fails loudly instead of reading as approval"

# --- install-cli, against a scratch HOME -------------------------------------

install_into() {
  ANCHOR_BIN_DIR="$1/bin" \
  ANCHOR_ZSH_COMPLETION_DIR="$1/.zsh/completions" \
  ANCHOR_ZSHRC="$1/.zshrc" \
  bash "$cli" install-cli 2>/dev/null
}

h="$work/home"
mkdir -p "$h"
install_into "$h"

[ -x "$h/bin/anchor" ] || fail "install-cli did not write an executable wrapper"
[ "$(bash "$h/bin/anchor" --version)" = "anchor $manifest_version" ] \
  || fail "the installed wrapper does not report the plugin version"
ok "install-cli writes a wrapper that runs and reports the plugin version"

grep -q 'exec bash' "$h/bin/anchor" || fail "the wrapper does not exec the CLI"
[ ! -L "$h/bin/anchor" ] || fail "the wrapper is a symlink; it must be a file recording the plugin path"
ok "the wrapper is a real file, not a link, so the freshness hook can compare versions"

[ -s "$h/.zsh/completions/_anchor" ] || fail "install-cli did not install the completion"
ok "install-cli installs the completion in the same step as the wrapper"

grep -q 'compinit' "$h/.zshrc" || fail "no compinit in the generated .zshrc"
grep -q 'fpath=' "$h/.zshrc" || fail "no fpath in the generated .zshrc"
ok "with no .zshrc, install-cli writes both the fpath line and compinit"

before=$(cksum < "$h/.zshrc")
install_into "$h"
[ "$(cksum < "$h/.zshrc")" = "$before" ] || fail "a second install-cli changed .zshrc again"
ok "install-cli is idempotent"

# fpath has to precede compinit or the completion never loads — the most common
# install bug, and invisible except by line order.
# The fixture directory name is kept clear of the words being grepped for — the
# fpath line embeds this path, so a dir named ...-compinit matches as a compinit
# line and the ordering assertion reads its own fixture.
h2="$work/home-b"
mkdir -p "$h2"
printf '# rc\nautoload -Uz compinit\ncompinit\n' > "$h2/.zshrc"
install_into "$h2"
fpath_ln=$(grep -n '^fpath=' "$h2/.zshrc" | head -1 | cut -d: -f1)
compinit_ln=$(grep -nE '(^|[[:space:]])compinit' "$h2/.zshrc" | head -1 | cut -d: -f1)
[ -n "$fpath_ln" ] || fail "install-cli did not add an fpath line to an existing .zshrc"
[ "$fpath_ln" -lt "$compinit_ln" ] \
  || fail "fpath landed at line $fpath_ln, at or after compinit at $compinit_ln"
ok "into a .zshrc that already runs compinit, the fpath line is inserted above it"

# An unrelated mention of a completions directory must not read as ours, or the
# fpath line is skipped and the completion silently never loads.
h3="$work/home-c"
mkdir -p "$h3"
# The literal $fpath is the zsh variable this fixture .zshrc references, not one
# for the test shell to expand.
# shellcheck disable=SC2016
printf '# rc\nfpath=(~/.oh-my-zsh/completions $fpath)\nautoload -Uz compinit\ncompinit\n' > "$h3/.zshrc"
install_into "$h3"
grep -q "$h3/.zsh/completions" "$h3/.zshrc" \
  || fail "another completions directory in .zshrc suppressed our own fpath line"
ok "someone else's completions directory does not read as ours"

# --- the SessionStart freshness hook -----------------------------------------
#
# The wrapper records a path at install time, so a plugin update leaves it on the
# old build. The hook is the only thing that notices, and it must never block.

hook="$root/hooks/cli-freshness.sh"
stub_bin="$work/stub-bin"
mkdir -p "$stub_bin"

# A wrapper of the shape `install-cli` writes — an exec into a plugin root baked
# in at install time — over a copy of the CLI whose manifest says $1. A stub that
# merely printf'd a version would pass while the real thing could not: the CLI
# prefers an inherited CLAUDE_PLUGIN_ROOT over its own location (CLI-02), so the
# old build reports the current version unless the hook clears it.
stub_wrapper_for() {
  local old="$work/old-plugin/$1"
  mkdir -p "$old/.claude-plugin" "$old/scripts/lib"
  printf '{\n  "name": "anchor",\n  "version": "%s"\n}\n' "$1" > "$old/.claude-plugin/plugin.json"
  cp "$cli" "$old/scripts/anchor"
  cp "$root/scripts/lib/plugin-version.sh" "$old/scripts/lib/plugin-version.sh"
  printf '#!/usr/bin/env bash\nexec bash "%s/scripts/anchor" "$@"\n' "$old" > "$stub_bin/anchor"
  chmod +x "$stub_bin/anchor"
}

run_hook() {
  set +e
  HOOK_OUT=$(PATH="$stub_bin:$PATH" CLAUDE_PLUGIN_ROOT="$root" bash "$hook" 2>&1)
  HOOK_RC=$?
  set -e
}

# No wrapper on PATH is not drift — the plugin works without one.
set +e
out=$(CLAUDE_PLUGIN_ROOT="$root" PATH="/usr/bin:/bin" bash "$hook" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "the hook exited $rc with no anchor on PATH, want 0"
[ -z "$out" ] || fail "the hook spoke with no anchor on PATH: $out"
ok "with no wrapper on PATH the hook stays silent"

stub_wrapper_for "$manifest_version"
run_hook
[ "$HOOK_RC" -eq 0 ] || fail "the hook exited $HOOK_RC on a current wrapper, want 0"
[ -z "$HOOK_OUT" ] || fail "the hook spoke about a current wrapper: $HOOK_OUT"
ok "a current wrapper produces no output"

stub_wrapper_for "0.0.1"
run_hook
[ "$HOOK_RC" -eq 0 ] || fail "the hook exited $HOOK_RC on drift; it must never block"
grep -q '0.0.1' <<<"$HOOK_OUT" || fail "the drift report did not name the stale version"
grep -q "$manifest_version" <<<"$HOOK_OUT" || fail "the drift report did not name the plugin version"
grep -q 'install-cli' <<<"$HOOK_OUT" || fail "the drift report did not name the fix"
ok "a stale wrapper is reported, naming both versions and the fix, without blocking"

# A wrapper too broken to report a version has not proven drift, and pipefail
# would otherwise surface its failure as a hook error every session.
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/anchor"
chmod +x "$stub_bin/anchor"
run_hook
[ "$HOOK_RC" -eq 0 ] || fail "the hook exited $HOOK_RC on an unreadable version, want 0"
[ -z "$HOOK_OUT" ] || fail "the hook guessed at drift it could not read: $HOOK_OUT"
ok "a wrapper that cannot report a version is not treated as drift"

echo "all anchor-cli tests passed"
