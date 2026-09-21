#!/usr/bin/env bash
# Drift guard for the documented `anchor.*` default values.
#
# A default is stated in more than one place on purpose: SPEC.md is normative,
# the Defaults table in guides/configuring.md is what a user reads, and each
# skill prompt and template restates the number where the drafting model meets
# it. Six files carry the three verbosity defaults between them, and a hand-sync
# is what this catches — nothing at run time reads these numbers back.
#
# The check is phrase-anchored, so a site states its default in one of the forms
# below or goes unchecked:
#
#   unset behaves as `25`        docs, skills, templates
#   unset behaves like ≈10       same, for an approximate one
#   it shall draft at `25`       SPEC.md
#
# The value is attributed to the nearest `anchor.<key>` named before it, within
# the same bullet, table row, or paragraph.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
table_doc="$root/guides/configuring.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

# Every source that may state a default. docs/ is shipyard's generated copy of
# guides/, and CHANGELOG.md records what past versions shipped — both would
# report a default that was true when written.
scan_files=("$root/SPEC.md")
for f in "$root"/guides/*.md "$root"/templates/*.md "$root"/rules/*.md "$root"/skills/*/SKILL.md; do
  scan_files+=("$f")
done

# --- the table: key -> default, for rows whose default is a bare integer ------
declared="$(mktemp)"
stated="$(mktemp)"
resolved="$(mktemp)"
trap 'rm -f "$declared" "$stated" "$resolved"' EXIT

awk '
  # A row is either a value ("`25`") or an alias to another key
  # ("`anchor.crVerbosity`", how the forge overrides fall back).
  /^## Defaults/       { in_table = 1; next }
  in_table && /^## /   { in_table = 0 }
  in_table && /^\|/ {
    n = split($0, cell, "|")
    if (n < 4) next
    key = cell[2]; val = cell[3]
    kind = ""
    if (match(val, /^ *`[0-9]+` *$/))                 kind = "num"
    else if (match(val, /^ *`anchor\.[^`]+` *$/))     kind = "alias"
    else next                                          # "none" and prose: not checked here
    match(val, /`[^`]+`/); v = substr(val, RSTART + 1, RLENGTH - 2)
    while (match(key, /`anchor\.[^`]+`/)) {
      print kind, tolower(substr(key, RSTART + 1, RLENGTH - 2)), tolower(v)
      key = substr(key, RSTART + RLENGTH)
    }
  }
' "$table_doc" > "$declared"

[ -s "$declared" ] || fail "no defaults parsed from the Defaults table in $table_doc"
ok "Defaults table parsed ($(awk '$1 == "num"' "$declared" | wc -l | tr -d ' ') values, $(awk '$1 == "alias"' "$declared" | wc -l | tr -d ' ') aliases)"

# --- every stated default across the sources ---------------------------------
awk '
  # A chunk is one bullet, table row, heading, or blank-line-delimited
  # paragraph — the window a key name and its default have to share.
  function flush() {
    if (chunk != "") scan(chunk, chunk_line)
    chunk = ""
  }
  function last_key(s,   k, rest, off) {
    k = ""; rest = s; off = 0
    while (match(rest, /anchor\.[A-Za-z][A-Za-z0-9.-]*/)) {
      k = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
    }
    sub(/[.,;:]$/, "", k)
    return k
  }
  # Digits within three characters of the phrase, so a phrase followed by prose
  # does not reach forward to an unrelated number.
  function value_after(s,   v) {
    if (match(s, /[0-9]+/) == 0) return ""
    if (RSTART > 4) return ""
    return substr(s, RSTART, RLENGTH)
  }
  function scan(text, line,   seen, pos, before, after, key, val) {
    seen = ""
    while (match(text, /[Uu]nset behaves (as|like)|it shall draft at/)) {
      pos = RSTART; len = RLENGTH
      before = seen substr(text, 1, pos - 1)
      after  = substr(text, pos + len)
      key = last_key(before)
      val = value_after(after)
      if (key != "" && val != "") print tolower(key), val, FILENAME ":" line
      seen = seen substr(text, 1, pos + len - 1)
      text = after
    }
  }
  /^[[:space:]]*$/           { flush(); next }
  /^[[:space:]]*[-*] /       { flush(); chunk_line = FNR }
  /^#/                       { flush(); chunk_line = FNR }
  /^\|/                      { flush(); chunk_line = FNR }
  {
    if (chunk == "") chunk_line = FNR
    chunk = chunk " " $0
  }
  END { flush() }
' "${scan_files[@]}" > "$stated"

[ -s "$stated" ] || fail "no default statements found — did the canonical phrasing change?"
ok "default statements found ($(wc -l < "$stated" | tr -d ' ') sites)"

# --- every stated default agrees with the table ------------------------------
mismatches=0
while read -r key val site; do
  # A forge override defaults to the key it aliases, so its default is that
  # key's — resolve one hop before comparing.
  alias_of="$(awk -v k="$key" '$1 == "alias" && $2 == k { print $3 }' "$declared")"
  [ -n "$alias_of" ] && key="$alias_of"
  echo "$key $val $site" >> "$resolved"
  want="$(awk -v k="$key" '$1 == "num" && $2 == k { print $3 }' "$declared")"
  if [ -z "$want" ]; then
    echo "FAIL: $site states a default for $key, which the Defaults table doesn't list" >&2
    mismatches=$((mismatches + 1))
  elif [ "$want" != "$val" ]; then
    echo "FAIL: $site says $key is $val; the Defaults table says $want" >&2
    mismatches=$((mismatches + 1))
  fi
done < "$stated"
[ "$mismatches" -eq 0 ] || fail "$mismatches site(s) disagree with $table_doc"
ok "every stated default matches the Defaults table"

# --- SPEC states a default for each verbosity dial ----------------------------
missing=0
while read -r kind key _; do
  [ "$kind" = "num" ] || continue
  case "$key" in
    *verbosity) ;;
    *) continue ;;
  esac
  if ! awk -v k="$key" '$1 == k && $3 ~ /SPEC\.md:/' "$resolved" | grep -q .; then
    echo "FAIL: SPEC.md states no default for $key (expected 'it shall draft at \`N\`')" >&2
    missing=$((missing + 1))
  fi
done < "$declared"
[ "$missing" -eq 0 ] || fail "$missing verbosity dial(s) have a documented default with no requirement behind it"
ok "SPEC.md carries a default for every verbosity dial"

echo "# all checks passed"
