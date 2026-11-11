#!/usr/bin/env bash
# Find what a draft should not carry to its destination: the spans the skill
# then replaces, or the user allows, before the approval gate (SPEC SANITIZE).
#
# What a draft contains is a fact, so this script decides it and the skill
# decides only what to say instead (SANITIZE-03). With nothing configured it
# finds (SANITIZE-04):
#
#   host        a hostname that is neither the destination's own nor a
#               well-known public one. In a URL any host counts; a bare word
#               counts when it is lower case and ends in a common or internal
#               top-level domain, which keeps `SKILL.md` and `System.Net` out.
#               The destination's own host covers its subdomains, and on a
#               host three labels deep its parent's too, so a self-hosted
#               GitLab's sibling services are unremarkable on that GitLab.
#   credential  a token shape (GitHub, GitLab, AWS, Slack, API-key, JWT, a
#               private key header), a `user:pass@host` URL, a bearer string.
#               Printed masked: the span is already in the draft, and this
#               output is one more place it would otherwise land.
#   path        an absolute local path through a user's home directory
#               (`/Users/<name>`, `/home/<name>`, `C:\Users\<name>`).
#   tracker     a link to a work tracker (Jira, Linear, a forge issue or CR)
#               on a host that is neither the destination's own nor a public
#               forge, whose readers can't follow it.
#
# And from configuration (SANITIZE-05/06), read with `git config --get-all`:
#
#   deny        each `anchor.deny` and `anchor.<forge>.deny` term, matched as a
#               literal, case-insensitively, wherever it appears.
#   allow       `anchor.allow` and `anchor.<forge>.allow` terms suppress a
#               finding above whose span contains one. They never suppress a
#               deny term.
#
# <forge> is the destination's: `github` for github.com, `gitlab` for a host
# naming GitLab, and none (the bare keys alone) otherwise.
#
# Output, one line per finding in source order, then the counts:
#
#   SANITIZE_DEST=<host>
#   SANITIZE_FORGE=<github|gitlab|none>
#   FINDING <kind> <source>:<line>:<column> <span>
#   FINDINGS=<n>
#   ALLOWED=<n>          findings an allow term suppressed
#
# <source> is a --file path as given, or the repo-relative path of a staged
# file, whose <line> is its line in the new version.
#
# Usage:
#   sanitize-check.sh [--repo <path>] [--dest-host <host>] [--forge <forge>]
#                     [--file <draft>]... [--staged [--path <p>]...]
#
#   --repo       the checkout whose `origin` and config apply (default: cwd)
#   --dest-host  the host the artifact publishes to; default `origin`'s host
#   --forge      override the forge read from the destination host
#   --file       drafted prose to scan; repeatable
#   --staged     scan the lines the index adds (SANITIZE-02), limited to the
#                --path list when one is given
#
# Exit codes:
#   0   nothing found
#   1   at least one finding
#   64  usage error
#   65  no destination, or the staged diff could not be read
#   66  a --file is unreadable
#   70  the scan itself failed

set -euo pipefail

usage() {
  echo "usage: sanitize-check.sh [--repo <path>] [--dest-host <host>] [--forge <forge>] [--file <draft>]... [--staged [--path <p>]...]" >&2
  exit 64
}

repo="."
dest=""
forge=""
staged=0
files=()
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      repo="${2:-}";  [[ -n "$repo" ]]  || usage; shift 2 ;;
    --dest-host) dest="${2:-}";  [[ -n "$dest" ]]  || usage; shift 2 ;;
    --forge)     forge="${2:-}"; [[ -n "$forge" ]] || usage; shift 2 ;;
    --file)      [[ -n "${2:-}" ]] || usage; files+=("$2"); shift 2 ;;
    --path)      [[ -n "${2:-}" ]] || usage; paths+=("$2"); shift 2 ;;
    --staged)    staged=1; shift ;;
    *) usage ;;
  esac
done
[[ ${#files[@]} -gt 0 || $staged -eq 1 ]] || usage
[[ ${#paths[@]} -eq 0 || $staged -eq 1 ]] || usage
case "$forge" in ""|github|gitlab|none) ;; *) usage ;; esac

for f in ${files[@]+"${files[@]}"}; do
  [[ -r "$f" && -f "$f" ]] || { echo "sanitize-check.sh: cannot read $f" >&2; exit 66; }
done

host_of_remote() {
  local u="${1#*://}" hostport
  hostport="${u%%/*}"
  hostport="${hostport##*@}"
  printf '%s' "${hostport%%:*}"
}

if [[ -z "$dest" ]]; then
  remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  dest=$(host_of_remote "$remote")
  [[ -n "$dest" ]] || {
    echo "sanitize-check.sh: no destination: $repo has no origin host, so pass --dest-host" >&2
    exit 65
  }
fi
dest=$(printf '%s' "$dest" | tr '[:upper:]' '[:lower:]')

if [[ -z "$forge" ]]; then
  case "$dest" in
    *github.com*) forge=github ;;
    *gitlab*)     forge=gitlab ;;
    *)            forge=none ;;
  esac
fi

terms() {
  git -C "$repo" config --get-all "anchor.$1" 2>/dev/null || true
  [[ "$forge" == none ]] || git -C "$repo" config --get-all "anchor.$forge.$1" 2>/dev/null || true
}

records() {
  local f
  for f in ${files[@]+"${files[@]}"}; do
    SRC="$f" awk '{ sub(/\r$/, ""); printf "%s\t%d\t%s\n", ENVIRON["SRC"], NR, $0 }' "$f" || return 1
  done
  if [[ $staged -eq 1 ]]; then
    printf '%s\n' "$diff" | awk '
      /^diff --git / { inhdr = 1; path = ""; next }
      inhdr && /^\+\+\+ / {
        p = substr($0, 5)
        if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2)
        if (p == "/dev/null") path = ""; else { sub(/^b\//, "", p); path = p }
        next
      }
      /^@@ / {
        inhdr = 0; h = $0
        sub(/^@@ -[0-9,]+ \+/, "", h); sub(/[ ,].*/, "", h); n = h + 0
        next
      }
      inhdr { next }
      /^\+/ {
        if (path != "") { t = substr($0, 2); sub(/\r$/, "", t); printf "%s\t%d\t%s\n", path, n, t }
        n++; next
      }
      /^ / { n++ }
    ' || return 1
  fi
}

diff=""
if [[ $staged -eq 1 ]]; then
  diff=$(git -C "$repo" diff --cached --no-color --no-ext-diff --no-renames -U0 -- ${paths[@]+"${paths[@]}"}) || {
    echo "sanitize-check.sh: could not read the staged diff in $repo" >&2
    exit 65
  }
fi

# Bytes, not characters: a locale-aware awk aborts on a byte sequence its locale
# can't decode, and every shape this scan looks for is ASCII.
export LC_ALL=C

recs=$(records) || {
  echo "sanitize-check.sh: could not read the text to scan" >&2
  exit 70
}

printf 'SANITIZE_DEST=%s\nSANITIZE_FORGE=%s\n' "$dest" "$forge"

rc=0
printf '%s' "$recs" | SANITIZE_DEST="$dest" SANITIZE_DENY="$(terms deny)" SANITIZE_ALLOW="$(terms allow)" awk '
function endswith(s, suf) {
  return length(s) >= length(suf) && substr(s, length(s) - length(suf) + 1) == suf
}

function spaces(n,    p) { p = ""; while (n-- > 0) p = p " "; return p }

# Overwrite a matched span in the scan copy so a later pass cannot see it again,
# keeping every column where it was.
function blank(col, len) { S = substr(S, 1, col - 1) spaces(len) substr(S, col + len) }

function allowed(raw,    i, r) {
  r = tolower(raw)
  for (i = 1; i <= NALLOW; i++) if (index(r, ALLOW[i])) return 1
  return 0
}

function add(kind, col, span, raw) {
  if (kind != "deny" && allowed(raw)) { NALLOWED++; return }
  NF_++
  FK[NF_] = kind; FC[NF_] = col; FS_[NF_] = span
}

function own(h) {
  return h == DEST || endswith(h, "." DEST) || \
         (PARENT != "" && (h == PARENT || endswith(h, "." PARENT)))
}

function public(h,    i, last, n, L) {
  sub(/^www\./, "", h)
  if (h in PUB) return 1
  for (i = 1; i <= NSUF; i++) if (h == SUF[i] || endswith(h, "." SUF[i])) return 1
  if (h == "localhost" || h == "0.0.0.0" || h ~ /^127\./) return 1
  n = split(h, L, "."); last = L[n]
  return (last == "example" || last == "test" || last == "invalid" || last == "localhost")
}

function pubforge(h) {
  return h == "github.com" || endswith(h, ".github.com") || h == "gitlab.com" || \
         h == "bitbucket.org" || h == "codeberg.org"
}

function tracker(h, url,    i) {
  for (i = 1; i <= NTRK; i++) if (h == TRK[i] || endswith(h, "." TRK[i])) return 1
  if (h ~ /jira|youtrack/) return 1
  url = tolower(url)
  return url ~ /\/browse\/[a-z][a-z0-9]*-[0-9]+/ || \
         url ~ /\/-\/(issues|merge_requests|work_items|epics)\// || \
         url ~ /\/(issues|pull|merge_requests)\/[0-9]/
}

function mask(tok,    i, c) {
  for (i = 1; i <= length(tok) && i <= 12; i++) {
    c = substr(tok, i, 1)
    if (c == "_" || c == "-") return substr(tok, 1, i) "***"
  }
  return substr(tok, 1, 4) "***"
}

# Every match of <re> in the scan copy, as parallel arrays of column and length.
function matches(re,    pos, n, rest) {
  n = 0; pos = 1
  while (pos <= length(S)) {
    rest = substr(S, pos)
    if (!match(rest, re)) break
    n++; MC[n] = pos + RSTART - 1; ML[n] = RLENGTH
    pos = MC[n] + RLENGTH
  }
  return n
}

function boundary(col) { return col == 1 || substr(S, col - 1, 1) !~ /[A-Za-z0-9_-]/ }

function credentials(    k, n, i, re, tok, col, len, body) {
  for (k = 1; k <= NTOK; k++) {
    n = matches(TOKRE[k])
    for (i = 1; i <= n; i++) {
      col = MC[i]; len = ML[i]; tok = substr(S, col, len)
      if (!boundary(col) || len < TOKMIN[k]) continue
      if (TOKRE[k] ~ /^\(AKIA/ && len != 20) continue
      if (TOKRE[k] ~ /^sk-/ && !(tok ~ /[0-9]/ && tok ~ /[A-Z]/)) continue
      add("credential", col, mask(tok), tok); blank(col, len)
    }
  }
  n = matches("[Bb]earer[ \t]+[A-Za-z0-9._~+/=-]+")
  for (i = 1; i <= n; i++) {
    col = MC[i]; len = ML[i]; tok = substr(S, col, len)
    body = tok; sub(/^[Bb]earer[ \t]+/, "", body)
    if (!boundary(col) || length(body) < 16) continue
    add("credential", col, substr(tok, 1, 6) " ***", tok); blank(col, len)
  }
  n = matches("-----BEGIN [A-Z ]*PRIVATE KEY-----")
  for (i = 1; i <= n; i++) {
    add("credential", MC[i], substr(S, MC[i], ML[i]), substr(S, MC[i], ML[i])); blank(MC[i], ML[i])
  }
}

function urls(    n, i, col, len, url, c, scheme, auth, at, j, ui, host, hcol, cut) {
  n = matches("[A-Za-z][A-Za-z0-9+.-]*://[^ \t<>\"'\''`(){}|]+")
  for (i = 1; i <= n; i++) {
    col = MC[i]; url = substr(S, col, ML[i])
    if ((cut = index(url, "[")) > 0) url = substr(url, 1, cut - 1)
    if ((cut = index(url, "]")) > 0) url = substr(url, 1, cut - 1)
    while (url ~ /[.,;:!?*_]$/) url = substr(url, 1, length(url) - 1)
    len = length(url)
    scheme = tolower(substr(url, 1, index(url, "://") - 1))
    if (scheme == "file") continue

    hcol = col + index(url, "://") + 2
    auth = substr(url, hcol - col + 1)
    for (j = 1; j <= length(auth); j++) {
      c = substr(auth, j, 1)
      if (c == "/" || c == "?" || c == "#") { auth = substr(auth, 1, j - 1); break }
    }
    at = 0
    for (j = length(auth); j > 0; j--) if (substr(auth, j, 1) == "@") { at = j; break }
    if (at) {
      ui = substr(auth, 1, at - 1)
      if (index(ui, ":")) {
        add("credential", col, scheme "://" substr(ui, 1, index(ui, ":")) "***@", ui)
      }
      auth = substr(auth, at + 1); hcol += at
    }
    if (auth ~ /^\[/) host = substr(auth, 2, index(auth, "]") - 2)
    else { host = auth; sub(/:.*/, "", host) }
    host = tolower(host); sub(/\.$/, "", host)

    if (host != "" && !own(host)) {
      if (tracker(host, url) && !pubforge(host)) add("tracker", col, url, url)
      else if (!public(host)) add("host", hcol, substr(S, hcol, length(host)), host)
    }
    blank(col, len)
  }
}

function paths(    n, i, col, tok, lead, seg, name, re) {
  n = matches("[^ \t<>\"'\''`(){}|,;]+")
  for (i = 1; i <= n; i++) {
    col = MC[i]; tok = substr(S, col, ML[i])
    if (tolower(substr(tok, 1, 7)) == "file://") { tok = substr(tok, 8); col += 7 }
    while (tok ~ /[.,:!?*]$/) tok = substr(tok, 1, length(tok) - 1)
    if (tok ~ /^\//) re = "/(Users|home)/[A-Za-z0-9._-]+"
    else if (tok ~ /^[A-Za-z]:[\\\/]/) re = "[\\\\/]Users[\\\\/][A-Za-z0-9._-]+"
    else continue
    if (!match(tok, re)) continue
    seg = substr(tok, RSTART + 1, RLENGTH - 1)
    name = tolower(substr(seg, match(seg, /[\\\/]/) + 1))
    if (name in NOTUSER) continue
    add("path", col, tok, tok); blank(col, length(tok))
  }
}

function hosts(    n, i, col, tok, prev, k, L) {
  n = matches("[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+")
  for (i = 1; i <= n; i++) {
    col = MC[i]; tok = substr(S, col, ML[i])
    prev = (col > 1) ? substr(S, col - 1, 1) : ""
    if (prev ~ /[\/\\_.$%]/ || tok != tolower(tok)) continue
    k = split(tok, L, ".")
    if (!(L[k] in TLD)) continue
    if (own(tok) || public(tok)) continue
    add("host", col, tok, tok)
  }
}

function emit(    i, j, t) {
  for (i = 2; i <= NF_; i++)
    for (j = i; j > 1 && FC[j - 1] > FC[j]; j--) {
      t = FK[j]; FK[j] = FK[j - 1]; FK[j - 1] = t
      t = FC[j]; FC[j] = FC[j - 1]; FC[j - 1] = t
      t = FS_[j]; FS_[j] = FS_[j - 1]; FS_[j - 1] = t
    }
  for (i = 1; i <= NF_; i++) printf "FINDING %s %s:%d:%d %s\n", FK[i], SRC, LINE, FC[i], FS_[i]
  TOTAL += NF_
}

BEGIN {
  DEST = ENVIRON["SANITIZE_DEST"]
  n = split(DEST, L, ".")
  PARENT = ""
  if (n >= 3) {
    PARENT = substr(DEST, index(DEST, ".") + 1)
    if (n == 3 && length(L[3]) == 2 && L[2] ~ /^(co|com|org|net|ac|gov|edu|ne|or)$/) PARENT = ""
  }

  NDENY = 0
  m = split(ENVIRON["SANITIZE_DENY"], T, "\n")
  for (i = 1; i <= m; i++) if (T[i] != "") DENY[++NDENY] = tolower(T[i])
  NALLOW = 0
  m = split(ENVIRON["SANITIZE_ALLOW"], T, "\n")
  for (i = 1; i <= m; i++) if (T[i] != "") ALLOW[++NALLOW] = tolower(T[i])

  # Exact hosts (a leading www. is ignored).
  m = split("google.com developers.google.com cloud.google.com youtube.com youtu.be " \
            "stackoverflow.com superuser.com serverfault.com askubuntu.com " \
            "pypi.org crates.io docs.rs rubygems.org nuget.org pkg.go.dev go.dev golang.org " \
            "nodejs.org asp.net x.com twitter.com linkedin.com medium.com " \
            "semver.org keepachangelog.com conventionalcommits.org json-schema.org " \
            "rfc-editor.org opensource.org creativecommons.org unpkg.com cdnjs.cloudflare.com " \
            "git-scm.com brew.sh cbea.ms revdiff.com mermaid.js.org", T, " ")
  for (i = 1; i <= m; i++) PUB[T[i]] = 1

  # Hosts and every subdomain of them.
  NSUF = split("github.com github.io githubusercontent.com githubassets.com " \
               "gitlab.com gitlab.io bitbucket.org codeberg.org sourceforge.net " \
               "example.com example.org example.net wikipedia.org stackexchange.com " \
               "npmjs.com npmjs.org python.org rust-lang.org mozilla.org microsoft.com " \
               "apple.com amazon.com docker.com docker.io kubernetes.io anthropic.com " \
               "claude.ai claude.com openai.com shields.io w3.org ietf.org jsdelivr.net " \
               "readthedocs.io readthedocs.org gnu.org kernel.org debian.org ubuntu.com", SUF, " ")

  NTRK = split("atlassian.net jira.com linear.app clickup.com asana.com monday.com " \
               "trello.com shortcut.com youtrack.cloud myjetbrains.com dev.azure.com " \
               "visualstudio.com", TRK, " ")

  # Top-level domains a bare word has to end in to read as a host. File
  # extensions that are also TLDs (md, sh, py, rs, pl, app) are left out.
  m = split("com net org io co ai dev cloud info biz us uk de fr nl eu ca au jp me tv xyz " \
            "internal local localdomain corp lan intranet home", T, " ")
  for (i = 1; i <= m; i++) TLD[T[i]] = 1

  m = split("shared public default runner user username you yourname", T, " ")
  for (i = 1; i <= m; i++) NOTUSER[T[i]] = 1

  NTOK = 0
  TOKRE[++NTOK] = "gh[pousr]_[A-Za-z0-9]+";                      TOKMIN[NTOK] = 24
  TOKRE[++NTOK] = "github_pat_[A-Za-z0-9_]+";                    TOKMIN[NTOK] = 40
  TOKRE[++NTOK] = "gl(pat|dt|rt|ptt|ft|soat|cbt|imt|agent|oas)-[A-Za-z0-9_-]+"; TOKMIN[NTOK] = 20
  TOKRE[++NTOK] = "(AKIA|ASIA)[A-Z0-9]+";                        TOKMIN[NTOK] = 20
  TOKRE[++NTOK] = "xox[abposr]-[A-Za-z0-9-]+";                   TOKMIN[NTOK] = 15
  TOKRE[++NTOK] = "sk-[A-Za-z0-9_-]+";                           TOKMIN[NTOK] = 32
  TOKRE[++NTOK] = "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; TOKMIN[NTOK] = 30
}

{
  i = index($0, "\t"); SRC = substr($0, 1, i - 1); rest = substr($0, i + 1)
  i = index(rest, "\t"); LINE = substr(rest, 1, i - 1); T0 = substr(rest, i + 1)
  S = T0; NF_ = 0

  lower = tolower(T0)
  for (d = 1; d <= NDENY; d++) {
    pos = 1
    while ((k = index(substr(lower, pos), DENY[d])) > 0) {
      col = pos + k - 1
      add("deny", col, substr(T0, col, length(DENY[d])), DENY[d])
      pos = col + length(DENY[d])
    }
  }

  credentials()
  urls()
  paths()
  hosts()
  emit()
}

END {
  printf "FINDINGS=%d\nALLOWED=%d\n", TOTAL, NALLOWED
  exit (TOTAL > 0)
}
' || rc=$?
exit "$rc"
