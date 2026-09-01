#!/usr/bin/env bash
# Turn the placeholders a CR description's Review guide is drafted with into
# finished forge deep links, so no line number is ever read off a diff by hand.
#
# The author writes what they are pointing at, as a markdown link whose
# destination is a path and a distinctive token from the target line:
#
#   [`scripts/deep-links.sh`](anchor:scripts/deep-links.sh#--resolve)
#   [`docs/x.md`](<anchor:docs/x.md#Deep-link construction (Review guide)>)
#   [`tests/x.test.sh`](anchor:tests/x.test.sh)          <- file-level, no token
#
# The angle-bracket form is plain markdown, and it is what carries a token with
# spaces or parentheses. Everything after the first `#` is the token; a literal
# substring, matched against the new side of the changed hunks in <base>...HEAD.
#
# Each forge anchors a diff line as <view-path>#<hash-of-file-path><line-part>,
# where the hash is of the repo-relative path (GitLab sha1, GitHub sha256) and
# the line part is `_<old>_<new>` on GitLab, `R<new>` on GitHub. This script owns
# the whole URL — the author sees neither half.
#
# Modes:
#   --check <draft>              resolve every placeholder, report what fails,
#                                write nothing. Needs only --base, so it runs
#                                before a CR exists — which is the point: the
#                                draft is checked before the author reviews it,
#                                and the CR is opened after they approve.
#   --expand <draft>             the same resolution, then rewrite the draft in
#                                place with finished URLs. Needs the CR URL, so
#                                it runs after the CR is opened. All-or-nothing:
#                                one unresolved placeholder leaves the file
#                                untouched.
#   --resolve <path> <token>     emit the finished link for one placeholder.
#                                An empty token gives the file-level link.
#   --verify <draft>             the backstop for links that were not written as
#                                placeholders — a description drafted before this
#                                convention, or a hand-built anchor. Reads each
#                                line part back against the working tree.
#
# Resolution reports one line per problem and exits non-zero:
#
#   UNRESOLVED ambiguous    <path> <token>   several changed lines match
#   UNRESOLVED absent       <path> <token>   the token is nowhere in the file
#   UNRESOLVED unchanged    <path> <token>   in the file, but not in a changed hunk
#   UNRESOLVED unknown-file <path> <token>   the path isn't in <base>...HEAD
#   UNRESOLVED malformed    <path> <token>   an `anchor:` outside a link destination
#
# `ambiguous` and `unchanged` list the candidate lines with their content, so the
# fix is to copy a longer, unique substring off the line that was meant. Nothing
# takes the first hit and nothing falls back to a file-level link: both would put
# a reviewer somewhere the bullet isn't describing, which is the failure the
# whole convention exists to remove.
#
# --verify reports, per link part:
#
#   out-of-range    the line is past the end of the file
#   blank-line      the target line is empty
#   unchanged-line  the line exists but isn't in a changed hunk of base...HEAD
#   unknown-file    an anchor whose hash matches no file in the range
#   malformed       the trailing line part is not a shape the forge resolves
#
# It cannot catch a link that landed on the wrong *changed* line — only the
# author knows which one was meant. Emits DEEP_LINK_SUSPECTS=<n> and exits 1
# when any are found, 0 when the draft is clean.
#
# Usage:
#   deep-links.sh --check   <draft.md>          --base <ref>
#   deep-links.sh --expand  <draft.md>  --forge <github|gitlab> --cr-url <url> --base <ref>
#   deep-links.sh --resolve <path> <token>  --forge … --cr-url … --base <ref>
#   deep-links.sh --verify  <draft.md>  --forge … --cr-url … --base <ref>
#
# Exit codes:
#   0   nothing to fix
#   1   something to fix (unresolved placeholders, or verify suspects)
#   64  usage error
#   66  the draft file is unreadable
#   69  no sha1/sha256 tool on the host

set -euo pipefail

# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

forge=""
cr_url=""
base=""
mode=""
draft=""
resolve_path=""
resolve_token=""

usage() { echo "deep-links.sh: $1" >&2; exit 64; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge)   forge="${2:?--forge needs github|gitlab|none}"; shift 2 ;;
    --cr-url)  cr_url="${2-}"; shift 2 ;;
    --base)    base="${2:?--base needs a ref}"; shift 2 ;;
    --check)   mode=check;  draft="${2:?--check needs a draft file}";  shift 2 ;;
    --expand)  mode='expand'; draft="${2:?--expand needs a draft file}"; shift 2 ;;
    --verify)  mode=verify; draft="${2:?--verify needs a draft file}"; shift 2 ;;
    --resolve)
      mode=resolve
      resolve_path="${2:?--resolve needs a path and a token}"
      [[ $# -ge 3 ]] || usage "--resolve needs a path and a token (use '' for a file-level link)"
      resolve_token="$3"
      shift 3
      ;;
    *) usage "unknown argument: $1" ;;
  esac
done

[[ -n "$mode" ]] || usage "one of --check, --expand, --resolve, --verify is required"
[[ -n "$base" ]] || usage "--base is required"
if [[ "$mode" == check ]]; then
  :
elif [[ -z "$forge" ]]; then
  usage "--forge is required for --$mode"
fi

if [[ "$mode" == check || "$mode" == expand || "$mode" == verify ]]; then
  [[ -r "$draft" ]] || { echo "deep-links.sh: cannot read draft: $draft" >&2; exit 66; }
fi

# Line *content* is read from the working tree; the changed-line set comes from
# base...HEAD. Those agree only on a clean tree — uncommitted edits shift content
# out from under the hunk set, and every line past them resolves against the
# wrong text. The skill runs this after its STATE=match check, so a dirty tree
# here means the caller skipped that; say so rather than emit confident nonsense.
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "deep-links.sh: working tree is dirty — line content is read from it while" >&2
  echo "  changed hunks come from ${base}...HEAD, so results will be off." >&2
  echo "DEEP_LINK_TREE=dirty"
fi

# --- Forge anchor scheme ------------------------------------------------------

case "$forge" in
  gitlab) algo=1;   view=diffs   ;;
  github) algo=256; view=changes ;;  # /changes, not /files — see cr-formatting.md
  *)      algo="";  view=""      ;;
esac

# Hash a path with the given algorithm. Neither name is available everywhere:
# macOS ships `shasum` and no `sha1sum`, Windows Git Bash ships `sha1sum` /
# `sha256sum` and no `shasum`, and distros vary. Try both before giving up.
path_hash() {
  local algo="$1" path="$2"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$path" | shasum -a "$algo" | cut -d' ' -f1
  elif command -v "sha${algo}sum" >/dev/null 2>&1; then
    printf '%s' "$path" | "sha${algo}sum" | cut -d' ' -f1
  else
    echo "deep-links.sh: no sha${algo} tool found (shasum or sha${algo}sum)" >&2
    exit 69
  fi
}

file_prefix() {
  local path="$1" hash
  hash=$(path_hash "$algo" "$path")
  case "$forge" in
    gitlab) printf '%s/%s#%s'      "$cr_url" "$view" "$hash" ;;
    github) printf '%s/%s#diff-%s' "$cr_url" "$view" "$hash" ;;
  esac
}

# The line part is all that differs by forge. GitLab wants both sides; the new
# number resolves for a modified line and for a pure addition alike, so it is
# used for both rather than carrying an old-side number nothing checks.
line_part() {
  case "$forge" in
    gitlab) printf '_%s_%s' "$1" "$1" ;;
    github) printf 'R%s'    "$1"      ;;
  esac
}

# --- The changeset ------------------------------------------------------------

changed_paths=$(git diff --name-only "${base}...HEAD" 2>/dev/null || true)

is_changed_path() { grep -qxF -- "$1" <<<"$changed_paths"; }

# New-side line numbers touched in base...HEAD, one per line. A `+c,0` hunk is a
# pure deletion and contributes none.
changed_lines() {
  git diff -U0 --no-color "${base}...HEAD" -- "$1" 2>/dev/null \
    | awk '/^@@/ {
        match($0, /\+[0-9]+(,[0-9]+)?/)
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        n = split(spec, a, ",")
        count = (n > 1 ? a[2] : 1)
        for (i = 0; i < count; i++) print a[1] + i
      }'
}

# --- Token resolution ---------------------------------------------------------
#
# Sets RESOLVE_KIND to `ok` plus RESOLVE_LINE, or to a failure kind plus
# RESOLVE_CANDIDATES (`<line>: <content>` rows, one per line).
RESOLVE_KIND=""; RESOLVE_LINE=""; RESOLVE_CANDIDATES=""

resolve() {
  local path="$1" token="$2" touched hits
  RESOLVE_KIND=""; RESOLVE_LINE=""; RESOLVE_CANDIDATES=""

  if ! is_changed_path "$path"; then
    RESOLVE_KIND="unknown-file"
    return
  fi

  # No token — a file-level link, which needs no line at all.
  if [[ -z "$token" ]]; then
    RESOLVE_KIND="ok"
    RESOLVE_LINE=""
    return
  fi

  touched=$(changed_lines "$path")
  if [[ -n "$touched" ]]; then
    # Two inputs, so the classic NR==FNR split — guarded above, because an empty
    # first file would make every line of the second one look like a line number.
    hits=$(awk -v tok="$token" '
      NR == FNR { want[$1 + 0] = 1; next }
      (FNR in want) && index($0, tok) { printf "%d: %s\n", FNR, $0 }
    ' <(printf '%s\n' "$touched") "$path")
  else
    hits=""
  fi

  local count
  count=$(grep -c . <<<"$hits" || true)
  [[ -z "$hits" ]] && count=0

  if [[ "$count" -eq 1 ]]; then
    RESOLVE_KIND="ok"
    RESOLVE_LINE="${hits%%:*}"
    return
  fi
  if [[ "$count" -gt 1 ]]; then
    RESOLVE_KIND="ambiguous"
    RESOLVE_CANDIDATES="$hits"
    return
  fi

  # No changed line carries it. Whether it is elsewhere in the file separates two
  # different authoring mistakes: a typo in the token, and a token that is real
  # but sits on a line this changeset never touched.
  local elsewhere
  elsewhere=$(grep -nF -- "$token" "$path" 2>/dev/null | sed 's/^\([0-9]*\):/\1: /' || true)
  if [[ -n "$elsewhere" ]]; then
    RESOLVE_KIND="unchanged"
    RESOLVE_CANDIDATES="$elsewhere"
  else
    RESOLVE_KIND="absent"
  fi
}

report_unresolved() {
  local kind="$1" path="$2" token="$3" why="$4"
  echo "UNRESOLVED $kind $path ${token:-<file-level>}"
  echo "  $why"
  if [[ -n "$RESOLVE_CANDIDATES" ]]; then
    while IFS= read -r row; do
      [[ -n "$row" ]] && echo "    $row"
    done <<<"$RESOLVE_CANDIDATES"
  fi
}

why_for() {
  case "$1" in
    ambiguous)    echo "several changed lines match — copy a longer, unique substring off the one you meant" ;;
    unchanged)    echo "present in the file, but not on a line ${base}...HEAD changed — point at a changed line, or drop the token for a file-level link" ;;
    absent)       echo "no line of the file contains it — check the spelling against the diff" ;;
    unknown-file) echo "${base}...HEAD does not touch this path" ;;
    malformed)    echo "an \`anchor:\` that is not a markdown link destination — write it as [text](anchor:<path>#<token>)" ;;
  esac
}

# --- Placeholder extraction ---------------------------------------------------
#
# A placeholder is always a link destination, in one of markdown's two forms.
# The angle form is what carries a token with spaces or parentheses; the bare
# form ends at the first `)`. The two patterns are disjoint — `](anchor:` cannot
# match inside `](<anchor:`.
placeholders() {
  {
    grep -o '](<anchor:[^>]*>)' "$1" || true
    grep -o '](anchor:[^)]*)'   "$1" || true
  } | sort -u
}

# An `anchor:` that no placeholder pattern claimed — the author wrote the spec as
# prose, or the link markup is broken. Silence there would ship the raw token.
stray_anchors() {
  local claimed
  claimed=$(placeholders "$1")
  grep -o 'anchor:[^)>[:space:]]*' "$1" 2>/dev/null | sort -u | while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    grep -qF -- "$a" <<<"$claimed" || echo "$a"
  done
}

# `anchor:<path>#<token>` -> path on stdout line 1, token on line 2. The first
# `#` splits: a path does not carry one, and a token may (`## Heading`).
spec_path() { local s="${1#anchor:}"; printf '%s' "${s%%#*}"; }
spec_token() {
  local s="${1#anchor:}"
  case "$s" in
    *#*) printf '%s' "${s#*#}" ;;
    *)   printf '' ;;
  esac
}

# Strip the markdown wrapper off a matched placeholder, leaving the spec.
spec_of() {
  local m="$1"
  m="${m#](}"; m="${m%)}"
  m="${m#<}";  m="${m%>}"
  printf '%s' "$m"
}

# --- check / expand -----------------------------------------------------------

run_resolution() {
  local write="$1" mapfile_path="$2"
  local total=0 unresolved=0 match spec path token link

  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    total=$((total + 1))
    spec=$(spec_of "$match")
    path=$(spec_path "$spec")
    token=$(spec_token "$spec")

    resolve "$path" "$token"
    if [[ "$RESOLVE_KIND" != "ok" ]]; then
      report_unresolved "$RESOLVE_KIND" "$path" "$token" "$(why_for "$RESOLVE_KIND")"
      unresolved=$((unresolved + 1))
      continue
    fi

    if [[ "$write" == "1" ]]; then
      link="$(file_prefix "$path")"
      [[ -n "$RESOLVE_LINE" ]] && link="${link}$(line_part "$RESOLVE_LINE")"
      printf '%s\t](%s)\n' "$match" "$link" >> "$mapfile_path"
    fi
  done < <(placeholders "$draft")

  while IFS= read -r stray; do
    [[ -z "$stray" ]] && continue
    total=$((total + 1))
    unresolved=$((unresolved + 1))
    RESOLVE_CANDIDATES=""
    report_unresolved malformed "$(spec_path "$stray")" "$(spec_token "$stray")" "$(why_for malformed)"
  done < <(stray_anchors "$draft")

  echo "PLACEHOLDERS=$total"
  echo "UNRESOLVED=$unresolved"
  [[ "$unresolved" -eq 0 ]]
}

if [[ "$mode" == check ]]; then
  run_resolution 0 /dev/null
  exit $?
fi

if [[ "$mode" == expand ]]; then
  if [[ -z "$cr_url" ]]; then
    if [[ -n "$(placeholders "$draft")" ]]; then
      echo "deep-links.sh: --expand needs --cr-url; the draft carries placeholders" >&2
      echo "  that only a CR URL can finish. Open the CR first." >&2
      exit 64
    fi
    echo "PLACEHOLDERS=0"
    echo "EXPANDED=0"
    exit 0
  fi

  map="$(anchor_tmpfile deep-links-map tsv)"
  : > "$map"
  trap 'rm -f "$map"' EXIT
  if ! run_resolution 1 "$map"; then
    echo "EXPANDED=0"
    exit 1
  fi

  if [[ -s "$map" ]]; then
    out="$(anchor_tmpfile deep-links-out md)"
    # Literal replacement, not regex: a token may hold any of `.[]*\^$`, and the
    # URL a `&`, each of which sed or a bash glob would reinterpret.
    awk -F'\t' '
      function lreplace(s, from, to,   out, p) {
        while ((p = index(s, from)) > 0) {
          out = out substr(s, 1, p - 1) to
          s = substr(s, p + length(from))
        }
        return out s
      }
      NR == FNR { from[++n] = $1; to[n] = $2; next }
      { line = $0; for (i = 1; i <= n; i++) line = lreplace(line, from[i], to[i]); print line }
    ' "$map" "$draft" > "$out"
    cat "$out" > "$draft"
    rm -f "$out"
  fi

  echo "EXPANDED=$(grep -c . "$map" || true)"
  exit 0
fi

# --- resolve ------------------------------------------------------------------

if [[ "$mode" == resolve ]]; then
  resolve "$resolve_path" "$resolve_token"
  if [[ "$RESOLVE_KIND" != "ok" ]]; then
    report_unresolved "$RESOLVE_KIND" "$resolve_path" "$resolve_token" "$(why_for "$RESOLVE_KIND")"
    exit 1
  fi
  link="$(file_prefix "$resolve_path")"
  [[ -n "$RESOLVE_LINE" ]] && link="${link}$(line_part "$RESOLVE_LINE")"
  echo "LINE=$RESOLVE_LINE"
  echo "LINK=$link"
  exit 0
fi

# --- verify -------------------------------------------------------------------
#
# The backstop for links that were not written as placeholders. Expansion makes
# the line part exact, so what reaches here is a description drafted before this
# convention or an anchor someone assembled by hand — where the number is a read
# off the diff, and a wrong one still resolves. The forge just scrolls to a line
# the bullet isn't describing, and nothing about the rendered link says so.

# Escape a literal prefix for use in a basic regular expression.
bre_escape() { printf '%s' "$1" | sed 's/[][\.*^$\\/]/\\&/g'; }

suspects=0
report() { echo "SUSPECT $1 $2:$3 $4"; suspects=$((suspects + 1)); }

# The line-part shapes each forge resolves. Anything else after the anchor is a
# fragment the browser drops, which lands the reader at the top of the diff —
# invisible to a check that questions the number and takes the shape as given.
case "$forge" in
  github) part_re='^\(R[0-9]\{1,\}\|L[0-9]\{1,\}\)$' ;;
  gitlab) part_re='^_[0-9]\{1,\}_[0-9]\{1,\}$' ;;
  *)      part_re='^$' ;;
esac

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  prefix=$(file_prefix "$path")
  esc=$(bre_escape "$prefix")

  # Everything the anchor carries up to whatever ends the link destination.
  tails=$(grep -o "${esc}[^)>\"[:space:]]*" "$draft" | sed "s|^${esc}||" | sort -u || true)
  [[ -z "$tails" ]] && continue

  total=$(wc -l < "$path" | tr -d ' ')
  touched=$(changed_lines "$path")

  while IFS= read -r tail; do
    [[ -z "$tail" ]] && continue          # a bare file-level link has nothing to check
    if ! grep -q "$part_re" <<<"$tail"; then
      report malformed "$path" 0 "line part '$tail' is not a shape ${forge} resolves"
      continue
    fi
    # Only the new side is checkable — the old side's content isn't in the tree.
    case "$forge" in
      github) [[ "$tail" == L* ]] && continue; n="${tail#R}" ;;
      gitlab) n="${tail##*_}" ;;
    esac
    if (( n > total )); then
      report out-of-range "$path" "$n" "file has $total lines"
    elif [[ -z "$(sed -n "${n}p" "$path" | tr -d '[:space:]')" ]]; then
      report blank-line "$path" "$n" "target line is empty"
    elif ! grep -qx "$n" <<<"$touched"; then
      report unchanged-line "$path" "$n" "not in a changed hunk of ${base}...HEAD"
    fi
  done <<<"$tails"
done <<<"$changed_paths"

# Anchors in the draft that belong to no file in the range at all.
case "$forge" in
  github) anchor_re='#diff-[0-9a-f]\{64\}' ;;
  gitlab) anchor_re='#[0-9a-f]\{40\}' ;;
  *)      anchor_re='' ;;
esac
if [[ -n "$anchor_re" ]]; then
  known=""
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    known+="$(file_prefix "$path")"$'\n'
  done <<<"$changed_paths"
  while read -r anchor; do
    [[ -z "$anchor" ]] && continue
    grep -qF -- "$anchor" <<<"$known" \
      || report unknown-file "$anchor" 0 "matches no file changed in ${base}...HEAD"
  done < <(grep -o "$anchor_re" "$draft" | sort -u || true)
fi

echo "DEEP_LINK_SUSPECTS=$suspects"
[[ "$suspects" -eq 0 ]]
