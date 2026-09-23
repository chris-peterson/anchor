#!/usr/bin/env bash
# Reads the `anchor.*` git config keys into one JSON object.
#
# Sourced, not executed. `anchor_config_json` prints `{key: value}` for every
# `anchor.*` key set in this repo or globally, `{}` when none is.
#
# Keys are named `anchor.<qualifier>.<setting>` — the qualifier saying what the
# setting applies to, the setting saying what is set, and a bare
# `anchor.<setting>` being the base (SPEC CONFIG-16). Two properties of git's own
# parsing shape what this has to do with them:
#
#   - A subsection is held case-sensitively where the section and the key are
#     folded, so `anchor.CR.verbosity` is a key no read of `anchor.cr.verbosity`
#     ever finds. Nothing errors; the setting is simply inert. So a qualifier
#     differing from a known one only by case is reported (CONFIG-20).
#   - `--get-regexp` emits the name with the section and key lowercased and the
#     subsection verbatim, which is why the case check reads the raw name here
#     rather than a normalized one.
#
# A key set under a name the current shape replaced is reported and not acted on
# (CONFIG-19). It is not carried to its replacement: the old CR keys `mrRules` /
# `prRules` were forge overrides *of the CR rules alone*, where `anchor.gitlab.*`
# / `anchor.github.*` qualify every artifact published to that forge, so a
# mechanical carry would widen what the user asked for.

# Superseded name -> the key that replaced it. Used to name the replacement in
# the warning; nothing here is read as a value.
anchor_config_renames() {
  cat <<'MAP'
anchor.crverbosity anchor.cr.verbosity
anchor.mrverbosity anchor.gitlab.verbosity
anchor.prverbosity anchor.github.verbosity
anchor.commitverbosity anchor.commit.verbosity
anchor.issueverbosity anchor.issue.verbosity
anchor.releaseverbosity anchor.release.verbosity
anchor.crrules anchor.cr.rules
anchor.mrrules anchor.gitlab.rules
anchor.prrules anchor.github.rules
anchor.commitrules anchor.commit.rules
anchor.issuerules anchor.issue.rules
anchor.crtemplaterepo anchor.cr.templateRepo
MAP
}

# The qualifiers anchor knows. A key whose qualifier matches one of these only
# case-insensitively is the CONFIG-20 trap.
anchor_config_qualifiers() {
  printf '%s\n' cr commit issue release github gitlab edit diff \
    prepare-review resolve-feedback merge review backlog pipeline
}

anchor_config_replacement() {
  local lower from to
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while read -r from to; do
    [[ "$lower" == "$from" ]] && { printf '%s' "$to"; return 0; }
  done < <(anchor_config_renames)
  return 1
}

# Prints one warning line per key that needs the user's attention. Separate from
# the JSON so a caller can put it on stderr without corrupting the KEY=value
# block its stdout carries.
anchor_config_warnings() {
  local name value repl qual known
  while read -r name value; do
    [[ -z "$name" ]] && continue
    if repl=$(anchor_config_replacement "$name"); then
      printf '%s no longer does anything — set %s instead.\n' "$name" "$repl"
      continue
    fi
    qual=$(printf '%s' "$name" | cut -s -d. -f2)
    [[ -z "$qual" ]] && continue
    while read -r known; do
      if [[ "$qual" != "$known" && \
            "$(printf '%s' "$qual" | tr '[:upper:]' '[:lower:]')" == "$known" ]]; then
        printf '%s has a qualifier git reads case-sensitively — nothing reads it; set %s instead.\n' \
          "$name" "${name/$qual/$known}"
        break
      fi
    done < <(anchor_config_qualifiers)
  done < <(git config --get-regexp '^anchor\.' 2>/dev/null || true)
}

anchor_config_json() {
  local json='{}' name value
  while read -r name value; do
    [[ -z "$name" ]] && continue
    json=$(jq -c --arg n "$name" --arg v "$value" '. + {($n): $v}' <<<"$json")
  done < <(git config --get-regexp '^anchor\.' 2>/dev/null || true)
  printf '%s' "$json"
}
