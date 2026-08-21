#!/usr/bin/env bash
# Portable unique-temp-path helper for anchor's forge scripts.
#
# Sourced, not executed. Prints a unique path under the temp dir with a chosen
# suffix; it does not create the file — a follow-up write treats the name as
# fresh (the same reason the guidance uses `mktemp -u`).
#
# Why not `mktemp .../NAME.XXXXXX.md` directly: mktemp's template rules differ
# by implementation. GNU coreutils expands an `XXXXXX` run anywhere and allows
# text after it, so `NAME.XXXXXX.md` works. BSD/macOS mktemp (which is what a
# script's non-interactive shell resolves when Homebrew's coreutils gnubin is
# not ahead on PATH) only replaces a *trailing* run — given `NAME.XXXXXX.md` it
# takes the whole string as a literal filename and creates `NAME.XXXXXX.md`
# verbatim. The first run "works"; the next run collides on that leftover file
# (`mktemp: mkstemp failed on …: File exists`) and the script dies.
#
# The portable subset that behaves identically on GNU, BSD, and Git Bash's
# mktemp: keep the `XXXXXX` trailing and append the suffix *outside* the
# template.
#
#   anchor_tmpfile cr-desc-current      -> <tmpdir>/cr-desc-current.a1B2c3.md
#   anchor_tmpfile issue-draft txt      -> <tmpdir>/issue-draft.d4E5f6.txt
#
# where <tmpdir> is $TMPDIR when set and /tmp otherwise — so /tmp on Linux and
# Git Bash, and /var/folders/<hash>/T on macOS, which always sets it.
#
# Why this honors $TMPDIR where anchor's *prescribed* guidance says a literal
# /tmp: the two answer to different readers. The bash safety analyzer reads the
# outer command line it is handed, and a caller's path-scoped allow rule matches
# a literal prefix — so a prescribed `mktemp "${TMPDIR:-/tmp}/…"` resolves to
# /var/folders/… on macOS, misses an `Edit(//tmp/**)` grant, and costs the caller
# a prompt on every body write. A mktemp *inside* `bash scripts/foo.sh` is
# invisible to the analyzer, so a script is free to respect a per-user temp dir.
# Prescribed text: literal /tmp. Script internals: $TMPDIR. The full reasoning,
# the platform table, and the allow rules are in guides/temp-paths.md;
# tests/tmp-path-guidance.test.sh holds both halves in place.

anchor_tmpfile() {
  local prefix="$1" ext="${2:-md}" dir="${TMPDIR:-/tmp}"
  dir="${dir%/}" # macOS TMPDIR carries a trailing slash; avoid a `//` in the path
  printf '%s.%s\n' "$(mktemp -u "${dir}/${prefix}.XXXXXX")" "$ext"
}
