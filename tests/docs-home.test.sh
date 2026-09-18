#!/usr/bin/env bash
# docs/README.md carries a hand-written Skills table, where the rest of the site
# gets its listings from shipyard's generated docs/_home.md partial.
#
# The partial emits the lede, Install, and the Skills/Rules/Hooks tables as one
# block, so including it forces the listings above anything the page adds after
# it. Getting started has to sit between Install and the listings, which is why
# Home composes its own top half and includes only docs/_tags.md.
#
# The cost is a table that no longer follows skills/ on its own. This is what
# makes it follow.
#
# The tagline has the same shape of problem from the other direction: plugin.yml
# owns it, .claude-plugin/plugin.json is projected from there, and the root
# README carries a hand-typed copy for a reader who never opens either.
# ci-platforms: linux macos

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
home="$root/docs/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

[[ -f "$home" ]] || fail "docs/README.md is missing"

# --- every skill on disk has a row, and no row names a skill that is gone ----
listed="$(grep -oE '^[|] [[][^]]*[]][(]/skills/[a-z-]+[)]' "$home" \
          | sed -E 's|.*/skills/([a-z-]+).*|\1|' | sort)"
ondisk="$(find "$root/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)"

[[ -n "$listed" ]] || fail "no skill rows found in docs/README.md, did the table move?"

missing="$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$ondisk"))"
[[ -z "$missing" ]] || fail "skills missing from Home's table: $(echo "$missing" | tr '\n' ' ')"
ok "every skill under skills/ has a row on Home"

extra="$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$ondisk"))"
[[ -z "$extra" ]] || fail "Home lists skills that no longer exist: $(echo "$extra" | tr '\n' ' ')"
ok "Home lists no skill that has been removed"

# --- each row links to that skill's own page --------------------------------
while read -r skill; do
  grep -qF "](/skills/$skill)" "$home" \
    || fail "Home's $skill row does not link to /skills/$skill"
done <<< "$ondisk"
ok "every row links to its skill page"

# --- the install commands still match plugin.yml's marketplace identity -----
grep -q 'chris-peterson/claude-marketplace' "$home" \
  || fail "Home's Install block names no marketplace"
grep -q 'claude plugin install anchor@chris-peterson' "$home" \
  || fail "Home's Install block does not install anchor@chris-peterson"
ok "the Install block still names the marketplace and the plugin"

# --- Getting started sits between Install and the listings ------------------
line_of() { grep -n "^## $1\$" "$home" | head -1 | cut -d: -f1; }
i="$(line_of 'Install')"; g="$(line_of 'Getting started')"; s="$(line_of 'Skills')"
[[ -n "$i" && -n "$g" && -n "$s" ]] || fail "Home is missing Install, Getting started, or Skills"
(( i < g && g < s )) || fail "Home's order is Install($i) Getting started($g) Skills($s); want Install < Getting started < Skills"
ok "Getting started sits between Install and the skill listing"

# --- Home must not re-include the generated partial -------------------------
if grep -q '_home.md' "$home"; then
  fail "Home includes _home.md again, which puts the listings back above Getting started"
fi
ok "Home composes its own top half rather than including _home.md"

# --- the root README's tagline still matches plugin.yml's description --------
readme="$root/README.md"
manifest="$root/plugin.yml"
[[ -f "$readme" && -f "$manifest" ]] || fail "README.md or plugin.yml is missing"

tagline="$(sed -n 's/^description: "\(.*\)"$/\1/p' "$manifest" | head -1)"
[[ -n "$tagline" ]] || fail "plugin.yml has no quoted top-level description to match against"

grep -qF "$tagline" "$readme" \
  || fail "README.md does not carry plugin.yml's description verbatim: $tagline"
ok "the root README's tagline matches plugin.yml"

echo "# all checks passed"
