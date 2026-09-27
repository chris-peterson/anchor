#!/usr/bin/env bash
# Functional test for scripts/lib/anchor-config.sh.
#
# The behaviors here come from git's own parsing rather than from anchor's
# choices, so they are exercised against a real repo rather than asserted: a
# subsection is case-sensitive where a two-level key name is folded (CONFIG-20),
# and a dotted qualifier only survives at the tail of a subsection (CONFIG-18).
# A key set under a superseded name is reported and left alone (CONFIG-19).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/anchor-config.sh
source "$here/../scripts/lib/anchor-config.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

repo=$(mktemp -d)
bare=$(mktemp -d)
cleanup() { rm -rf "$repo" "$bare"; }
trap cleanup EXIT

cd "$repo"
git init -q .
# A global anchor.* key would leak into every read below.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

get() { jq -r --arg k "$1" '.[$k] // "<unset>"' <<<"$(anchor_config_json)"; }

# Captured rather than piped: `grep -q` exits on its first match, which lands
# SIGPIPE on the producer and, under `pipefail`, reads as a failed assertion.
warns() { anchor_config_warnings; }
warned() { grep -q "$1" <<<"$(warns)"; }

# --- the shape itself ---------------------------------------------------------

git config anchor.verbosity 25
git config anchor.issue.verbosity 75
git config anchor.github.verbosity 10
[[ $(get anchor.verbosity)        == 25 ]] || fail "base key"
[[ $(get anchor.issue.verbosity)  == 75 ]] || fail "artifact qualifier"
[[ $(get anchor.github.verbosity) == 10 ]] || fail "forge qualifier"
ok "base, artifact, and forge qualifiers each resolve"

# Qualifier-before-setting is fixed for every key so that a dotted qualifier — a
# specific host, should one ever be wanted — stays addable without moving the
# keys that exist (CONFIG-18). A dotted name only survives at the tail of the
# subsection, and the mis-parse is invisible through --get-regexp, which re-emits
# the full dotted name either way; it is read off how git stored it.
git config anchor.github.com.deny acme
grep -q '^\[anchor "github.com"\]$' .git/config \
  || fail "qualifier-first did not store the dotted qualifier as the subsection"
ok "a dotted qualifier at the tail of the subsection stores as [anchor \"github.com\"] deny"

git config anchor.deny.github.com acme
grep -q '^\[anchor "deny.github"\]$' .git/config \
  || fail "setting-first mis-parse not observed"
ok "a dotted name ahead of the setting splits into subsection 'deny.github', key 'com'"

git config --remove-section 'anchor.github.com'
git config --remove-section 'anchor.deny.github'

# --- CONFIG-19: superseded names are reported, not carried ------------------

git config anchor.crVerbosity 50
[[ $(get anchor.cr.verbosity) == "<unset>" ]] || fail "superseded name was carried"
ok "a key set under its superseded name does not reach its replacement"

warned 'anchor.crverbosity no longer does anything' \
  || fail "no warning for the superseded name"
warned 'set anchor.cr.verbosity instead' \
  || fail "warning does not name the replacement"
ok "the superseded name is reported with the key that replaced it"

git config --unset anchor.crVerbosity

# --- CONFIG-20: a qualifier is case-sensitive --------------------------------

git config anchor.CR.rules "from the wrong spelling"
[[ $(get anchor.cr.rules) == "<unset>" ]] || fail "git folded a subsection"
ok "git holds a subsection case-sensitively, so a mis-cased qualifier is inert"

# A base key, so it survives the rename and can still show the contrast: git
# folds a two-level name whole, which is exactly why a qualifier not being
# folded is the trap it is.
git config anchor.reviewBudgetMins 5
[[ $(get anchor.reviewbudgetmins) == 5 ]] || fail "two-level name not folded"
ok "a two-level key name is still folded, which is what makes the contrast a trap"

warned 'anchor.CR.rules has a qualifier git reads case-sensitively' \
  || fail "no warning for the mis-cased qualifier"
warned 'set anchor.cr.rules instead' \
  || fail "warning does not name the spelling that would be read"
ok "a qualifier differing only by case is reported with the spelling that works"

# --- a forge key is not a renamed CR key -------------------------------------

# anchor.prRules was a forge override of the CR rules alone; anchor.github.rules
# qualifies every artifact published to GitHub. Carrying one to the other would
# widen the setting, which is why no carry happens at all.
git config anchor.prRules "fill in Risk & rollback"
[[ $(get anchor.github.rules) == "<unset>" ]] || fail "prRules was carried to github.rules"
warned 'anchor.prrules no longer does anything' \
  || fail "prRules not reported"
ok "a superseded forge key is reported rather than widened onto every artifact"

git config --unset anchor.prRules

# --- an empty config is not a failure ----------------------------------------

git -C "$bare" init -q .
[[ $(cd "$bare" && anchor_config_json) == '{}' ]] || fail "empty config is not {}"
[[ -z $(cd "$bare" && anchor_config_warnings) ]] || fail "empty config warned"
ok "a repo with no anchor.* keys yields {} and warns nothing"

echo "# all checks passed"
