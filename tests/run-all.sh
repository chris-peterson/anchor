#!/usr/bin/env bash
# Run every suite in tests/ that declares this platform, and report all of them.
#
# One runner for both callers — `just test` and the test.yml matrix job — so a
# suite is discovered rather than wired up twice. Where a suite is expected to
# hold is the suite's own business, declared in its header:
#
#   # ci-platforms: linux macos windows
#
# Absent, a suite runs on linux and macos. Every suite passes on both, under
# bash 3.2 as well as 5, which is what makes that default a claim rather than a
# guess. `windows` is opt-in because Git Bash is where the untested ground is —
# the suites that name it are the ones whose subject *is* a platform difference
# (which mktemp the shell resolves, whether the host has sha1sum).
#
# Every suite runs even after one fails, since a platform-specific break is
# usually several suites wide and the second failure is what names the cause.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Linux)                  platform=linux ;;
  Darwin)                 platform=macos ;;
  MINGW* | MSYS* | CYGWIN*) platform=windows ;;
  *) echo "unrecognized platform: $(uname -s)" >&2; exit 1 ;;
esac

declared_platforms() {
  # First `# ci-platforms:` line in the header, `all` expanded.
  local line
  line="$(grep -m1 -E '^# ci-platforms:' "$1" || true)"
  line="${line#*:}"
  case "$line" in
    *all*) echo "linux macos windows" ;;
    "")    echo "linux macos" ;;
    *)     echo "$line" ;;
  esac
}

failed=()
skipped=()
ran=0

for suite in "$here"/*.test.sh; do
  name="$(basename "$suite")"
  if [[ " $(declared_platforms "$suite") " != *" $platform "* ]]; then
    skipped+=("$name")
    continue
  fi
  printf '\n=== %s\n' "$name"
  ran=$((ran + 1))
  bash "$suite" || failed+=("$name")
done

[[ $ran -gt 0 ]] || { echo "no suite declared $platform — the discovery glob or the markers are wrong" >&2; exit 1; }

printf '\n'
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "skipped on $platform (${#skipped[@]}): ${skipped[*]}"
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED on $platform (${#failed[@]}/$ran): ${failed[*]}" >&2
  exit 1
fi

echo "$ran suite(s) passed on $platform"
