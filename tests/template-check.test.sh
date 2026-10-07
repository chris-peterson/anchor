#!/usr/bin/env bash
# Functional test for scripts/template-check.sh — the template placeholders and
# the checkboxes a description composed into a team template still owes before
# it ships.
# ci-platforms: linux macos windows
#   The scan is one awk program, and BSD awk, gawk, and mawk differ in what
#   regex syntax they accept.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../scripts/template-check.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$2"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-template-check-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

run() {
  rc=0
  out="$(bash "$check" --template "$1" "$2")" || rc=$?
}

cat > "$work/template.md" <<'EOF'
## Summary

< Type your summary here >

## Notes
TODO
Rollout plan: TBD.
<!-- Describe how you tested this.
     Include logs if relevant. -->
<issue link>

```text
<not a template placeholder>
```

## Checklist

- [x] Tests added
- [ ] Breaking change
EOF

# --- a filled-in draft ------------------------------------------------------
cat > "$work/filled.md" <<'EOF'
## Summary

Adds retries to the upload client.

## Notes
Rollout plan: behind the `retries` flag, on for staging first.
<!-- a comment the drafter wrote -->
Removes a TODO from the client, and `Result<T>` now carries the retry count.
Generic over <T> and a {placeholder} in braces, written by the drafter.
Closes #12.

<details>
<summary>Sample output</summary>

```text
TODO: this is output, inside a fence
< Type your summary here >
```

</details>
EOF
run "$work/template.md" "$work/filled.md"
[[ "$rc" == 0 ]] || fail "filled draft exited $rc: $out"
[[ "$(val PLACEHOLDERS "$out")" == 0 ]] || fail "filled draft reported placeholders: $out"
ok "the drafter's own comments, angle brackets, braces, and TODO prose are not placeholders"

# --- placeholders left behind ----------------------------------------------
cat > "$work/leftover.md" <<'EOF'
## Summary

< Type your summary here >

## Notes
TODO
Rollout plan: TBD.
<!-- Describe how you tested this.
     Include logs if relevant. -->
See <issue link>.
EOF
run "$work/template.md" "$work/leftover.md"
[[ "$rc" == 1 ]] || fail "leftovers exited $rc, want 1: $out"
[[ "$(val PLACEHOLDERS "$out")" == 5 ]] || fail "want 5 placeholders: $out"
grep -q '^PLACEHOLDER 3 < Type your summary here >: ' <<<"$out" || fail "angle prompt not reported: $out"
grep -q '^PLACEHOLDER 6 TODO: TODO$' <<<"$out" || fail "bare TODO not reported: $out"
grep -q '^PLACEHOLDER 7 TBD: ' <<<"$out" || fail "TBD line not reported: $out"
grep -q '^PLACEHOLDER 8 <!--: ' <<<"$out" || fail "comment not reported: $out"
grep -q '^PLACEHOLDER 9 ' <<<"$out" && fail "comment continuation reported twice: $out"
grep -q '^PLACEHOLDER 10 <issue link>: ' <<<"$out" || fail "angle token mid-line not reported: $out"
ok "each template placeholder carried into the draft is reported by line"

# --- checkboxes ------------------------------------------------------------
cat > "$work/boxes.md" <<'EOF'
## Checklist

- [x] Tests added
- [ ] Breaking change
* [X] Docs updated
1. [ ] Migration included
- [] not a checkbox
EOF
run "$work/template.md" "$work/boxes.md"
[[ "$rc" == 0 ]] || fail "checkboxes alone exited $rc, want 0: $out"
[[ "$(val CHECKBOXES "$out")" == 4 ]] || fail "want 4 checkboxes: $out"
grep -q '^CHECKBOX 3 checked: Tests added$' <<<"$out" || fail "checked box: $out"
grep -q '^CHECKBOX 4 unchecked: Breaking change$' <<<"$out" || fail "unchecked box: $out"
grep -q '^CHECKBOX 5 checked: Docs updated$' <<<"$out" || fail "uppercase X: $out"
grep -q '^CHECKBOX 6 unchecked: Migration included$' <<<"$out" || fail "numbered item: $out"
ok "every checkbox is listed with its state, and none fails the check"

# --- usage -----------------------------------------------------------------
rc=0; bash "$check" "$work/boxes.md" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 64 ]] || fail "no --template exited $rc, want 64"
rc=0; bash "$check" --template "$work/template.md" "$work/missing.md" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 66 ]] || fail "missing draft exited $rc, want 66"
rc=0; bash "$check" --template "$work/missing.md" "$work/boxes.md" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 66 ]] || fail "missing template exited $rc, want 66"
ok "usage and unreadable-file exits"
