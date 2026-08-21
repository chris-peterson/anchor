#!/usr/bin/env bash
# Guards the two halves of anchor's temp-path position, which pull in opposite
# directions and are easy to "fix" into agreement:
#
#   prescribed text  -> a literal /tmp, because a caller's path-scoped allow rule
#                       matches a prefix and `${TMPDIR:-/tmp}` resolves to
#                       /var/folders/... on macOS, missing an Edit(//tmp/**)
#                       grant and costing a prompt on every body write.
#   script internals -> $TMPDIR, because the safety analyzer reads only the outer
#                       command line, so a mktemp inside `bash scripts/foo.sh` is
#                       invisible to it and may respect a per-user temp dir.
#
# Nothing reads either at run time, so this is what keeps them from drifting.
#
# Runs on the ubuntu / macOS / Windows-Git-Bash matrix because the claims in
# guides/temp-paths.md are per-platform: whether TMPDIR is set, and whether a
# literal /tmp is writable and what it resolves to.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

# The sites that prescribe a temp path to the caller. Prose the analyzer reads.
prescribed=(
  rules/use-forge-clis.md
  guides/forge-cookbook.md
  guides/temp-paths.md
  skills/commit/SKILL.md
  skills/issue/SKILL.md
  skills/resolve-feedback/SKILL.md
)

# --- prescribed text carries no $TMPDIR template ---------------------------
for rel in "${prescribed[@]}"; do
  [[ -f "$root/$rel" ]] || fail "prescribed site is missing: $rel"
  if grep -n 'mktemp[^`]*TMPDIR' "$root/$rel"; then
    fail "$rel prescribes a \$TMPDIR mktemp template; use a literal /tmp"
  fi
done
ok "no prescribed site templates a temp path on \$TMPDIR"

# Every site that prescribes an mktemp prescribes the literal-/tmp form.
for rel in "${prescribed[@]}"; do
  grep -q 'mktemp' "$root/$rel" || continue
  grep -q 'mktemp -u /tmp/' "$root/$rel" \
    || fail "$rel prescribes mktemp without the literal /tmp form"
done
ok "every prescribed mktemp uses the literal /tmp form"

# --- the guidance states its platform scope and pairs path with rule --------
guide="$root/guides/temp-paths.md"
grep -q 'POSIX shell' "$guide"          || fail "the guide does not state its shell assumption"
grep -q 'PowerShell'  "$guide"          || fail "the guide does not cover the PowerShell-only case"
grep -q 'Edit(//tmp/\*\*)' "$guide"     || fail "the guide does not name the /tmp allow rule"
grep -q 'Edit(//private/tmp/\*\*)' "$guide" \
  || fail "the guide does not name the macOS /private/tmp allow rule"
ok "the guide states its platform scope and names both allow rules"

# --- the sequenced exit-status read appears only as a counter-example -------
# The shape has to stay quotable: naming it is how the guidance teaches which
# form is refused. What must not come back is a site *telling* the caller to
# write it, so every occurrence has to sit in a sentence that rules it out.
ruled_out='gated|refused|cannot|can.t|no allow rule|instead of'
for rel in "${prescribed[@]}"; do
  while IFS= read -r line; do
    grep -Eqi "$ruled_out" <<<"$line" && continue
    fail "$rel names \`echo \"exit: \$?\"\` without ruling it out: $line"
  done < <(grep -n 'echo "exit: \$?"' "$root/$rel" || true)
done
ok "the sequenced exit-status read appears only as a ruled-out counter-example"

# --- the script half still honors $TMPDIR ----------------------------------
# The asymmetry is the point: a sweep that "fixed" this to a literal /tmp would
# take a per-user temp dir away from every script for no gain.
grep -q 'TMPDIR' "$root/scripts/lib/tmpfile.sh" \
  || fail "scripts/lib/tmpfile.sh should honor \$TMPDIR; see guides/temp-paths.md"
grep -q 'guides/temp-paths.md' "$root/scripts/lib/tmpfile.sh" \
  || fail "tmpfile.sh should point at the guide that reconciles the two positions"
ok "scripts/lib/tmpfile.sh honors \$TMPDIR and cites the reconciliation"

# --- the prescribed form actually works on this platform -------------------
# The per-platform half. A literal /tmp has to be writable wherever the guidance
# claims to apply, and the path it resolves to is what a permission check sees.
p="$(mktemp -u /tmp/anchor-tmp-path.XXXXXX).md"
echo "# sample: $p"
[[ "$p" == /tmp/* ]]       || fail "prescribed form did not land under /tmp: $p"
[[ "$p" != *XXXXXX* ]]     || fail "template not expanded: $p"
[[ "$p" == *.md ]]         || fail "suffix lost: $p"
printf 'body\n' > "$p"
[[ -f "$p" ]]              || fail "prescribed path is not writable: $p"

q="$(mktemp -u /tmp/anchor-tmp-path.XXXXXX).md"
[[ "$p" != "$q" ]]         || fail "consecutive calls collided: $p"
rm -f "$p"
ok "the prescribed literal-/tmp form is unique and writable here"

# What a permission check sees. On macOS /tmp is a symlink to private/tmp, which
# is why the guide tells a caller to grant both prefixes.
real="$(cd /tmp && pwd -P)"
echo "# /tmp resolves to: $real"
case "$(uname -s)" in
  Darwin)
    [[ "$real" == /private/tmp ]] \
      || fail "expected macOS /tmp -> /private/tmp, got $real; the guide's both-rules claim rests on this"
    ok "macOS resolves /tmp to /private/tmp, so both allow rules are needed"
    ;;
  Linux)
    [[ "$real" == /tmp ]] || fail "expected Linux /tmp to be its own real path, got $real"
    ok "Linux resolves /tmp to itself, so Edit(//tmp/**) alone covers it"
    ;;
  *)
    # Git Bash on Windows. /tmp is a mount over the user's own temp directory, so
    # the real path is per-user and there is no shared second prefix to grant —
    # the guide's table says so, and this is what holds it to it. Asserting that
    # it resolves *elsewhere* is the point: a branch that accepted any value is
    # how a wrong row survived a green run once already.
    [[ "$real" != /tmp ]] \
      || fail "expected Git Bash to resolve /tmp to a mount elsewhere, got $real; the guide's per-user row rests on this"
    grep -q 'mount over the user' "$guide" \
      || fail "the guide should state that Git Bash mounts /tmp over the user's temp dir"
    ok "Git Bash resolves /tmp to $real, a per-user path with no shared prefix to grant"
    ;;
esac

echo "# all checks passed"
