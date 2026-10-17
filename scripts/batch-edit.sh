#!/usr/bin/env bash
# The deterministic half of reviewing several drafted edits as one set: the tree
# revdiff shows them in, the notes that carry review-only context, the
# `.batch-edit.md` table of them, and what the reviewer decided for each item
# when the review closed. The skill drafts each edit and publishes what was kept;
# this script lays the set out and reads the answer back.
#
# A batch is a scratch git repo in a temp directory. Each item is one file in it:
# its current text is committed as the base, and its proposed text is written
# over it, so the diff from the base to the tree is every proposed edit, one file
# per item. An item with no current text (a new issue, a new reply) is a new
# file. Nothing here touches the user's checkout.
#
# Usage:
#   batch-edit.sh start  --items <items.json> [--title <text>]
#   batch-edit.sh read   --dir <batch> --returned <notes.returned.json>
#   batch-edit.sh finish --dir <batch>
#
# The items file `start` reads, written by the skill:
#   {"items": [{"id": "<what the table calls it, e.g. an issue or thread number>",
#               "file": "<path in the batch tree, e.g. issues/<n>.md>",
#               "current": "<file holding the text as it stands; omit for a new item>",
#               "proposed": "<file holding the drafted text>",
#               "summary": "<one line for the table>",
#               "url": "<where the item lives on the web; omit for a new item>",
#               "notes": [{"line": <n>, "body": "<context for this review only>"},
#                         {"body": "<a note on the whole file>"}]}]}
# An id is any one line of text other than `#`, unique in the batch; a `|` in it
# is escaped in the table. A note's line is numbered in the proposed text. Notes are never published:
# they carry what the reviewer needs to judge the edit and nothing the artifact
# should keep.
#
# A proposed text may open with a header block, `key: value` lines ended by a
# `---` line, for the fields that travel with a body (an issue's title, labels,
# state). `read` splits it back out for each item that was seeded with one. A
# proposed text that opens like a header but never closes one is refused: two or
# more `key: value` lines, a line starting `---` that isn't `---` alone, or an
# item whose current text has a header.
#
# Output is KEY=value lines on stdout. A failure prints BATCH_ERROR=<message>
# and exits non-zero rather than leaving a half-written batch.

set -euo pipefail

# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

TABLE=".batch-edit.md"

die() { echo "BATCH_ERROR=$*"; exit 65; }

cmd="${1:-}"
[[ -n "$cmd" ]] || { echo "usage: batch-edit.sh <start|read|finish> ..." >&2; exit 64; }
shift

dir="" items="" returned="" title=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      dir="${2:?--dir needs a path}"; shift 2 ;;
    --items)    items="${2:?--items needs a file}"; shift 2 ;;
    --returned) returned="${2:?--returned needs a file}"; shift 2 ;;
    --title)    title="${2:?--title needs text}"; shift 2 ;;
    *) echo "batch-edit.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# The scratch repo commits under its own identity, with no hooks and no signing,
# whatever the user's global config asks of a commit.
sgit() {
  git -C "$root" -c user.name=anchor -c user.email=anchor@localhost \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

need_dir() {
  [[ -n "$dir" && -f "$dir/batch.json" ]] || { echo "batch-edit.sh: --dir must name a batch that start created" >&2; exit 64; }
  root="$dir/tree"
}

# 1 when a text opens with a header block: `key: value` lines, then `---`.
has_header() {
  awk 'NR == 1 && $0 == "---" { exit 1 }
       $0 == "---" { found = 1; exit 0 }
       !/^[A-Za-z][A-Za-z0-9_-]*:( |$)/ { exit 1 }
       END { exit found ? 0 : 1 }' "$1"
}

# 1 when a text opens with `key: value` lines but has_header can't close them
# into a header block, so splitting it would leave the fields in the body.
broken_header() {
  local current="$1" proposed="$2"
  has_header "$proposed" && return 1
  awk -v cur="$current" '
    NR == 1 && !/^[A-Za-z][A-Za-z0-9_-]*:( |$)/ { exit 1 }
    /^[A-Za-z][A-Za-z0-9_-]*:( |$)/ { keys++; next }
    { if (/^---/) bad = 1; exit }
    END { exit (bad || keys > 1 || cur) ? 0 : 1 }' "$proposed" || return 1
}

case "$cmd" in

start)
  [[ -n "$items" && -r "$items" ]] || { echo "batch-edit.sh start needs a readable --items file" >&2; exit 64; }
  jq -e '.items | type == "array" and length > 0' "$items" >/dev/null 2>&1 || die "$items has no items"
  errors=()
  while IFS=$'\x1f' read -r iid file current proposed; do
    case "$iid" in
      ""|"#"|*$'\x1e'*) errors+=("item ${iid//$'\x1e'/ }: an id is one line of text other than #"); continue ;;
    esac
    [[ -n "$file" ]] || { errors+=("item $iid: no file"); continue; }
    case "/$file/" in
      */../*|//*) errors+=("item $iid $file: the file must be a relative path inside the batch") ;;
    esac
    [[ "$file" != "$TABLE" ]] || errors+=("item $iid: $TABLE is the batch's own table")
    [[ -r "$proposed" ]] || { errors+=("item $iid: the proposed text $proposed is not readable"); continue; }
    cur_header=""
    if [[ -n "$current" ]]; then
      [[ -r "$current" ]] || { errors+=("item $iid: the current text $current is not readable"); continue; }
      ! cmp -s "$current" "$proposed" || errors+=("item $iid $file: the proposed text is the current text")
      ! has_header "$current" || cur_header=1
    fi
    ! broken_header "$cur_header" "$proposed" \
      || errors+=("item $iid $file: opens with key: value lines but no --- line ends the header")
  done < <(jq -r '.items[] | [(.id // "" | tostring | gsub("\n"; "\u001e")), (.file // ""), (.current // ""), (.proposed // "")] | join("\u001f")' "$items")
  dupes=$(jq -r '[.items[].id|tostring] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$items")
  [[ -z "$dupes" ]] || errors+=("ids used more than once: $dupes")
  dupes=$(jq -r '[.items[].file] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$items")
  [[ -z "$dupes" ]] || errors+=("files used more than once: $dupes")
  if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo "BATCH_ERROR=$e"; done
    exit 65
  fi

  dir=$(anchor_tmpdir anchor-batch)
  root="$dir/tree"
  trap 'echo "BATCH_ERROR=start stopped at line $LINENO; the batch was not laid out"; rm -rf "$dir"; exit 65' ERR
  mkdir -p "$root" "$dir/seeded"
  git init --quiet "$root"
  n=$(jq '.items | length' "$items")
  for ((i = 0; i < n; i++)); do
    file=$(jq -r --argjson i "$i" '.items[$i].file' "$items")
    current=$(jq -r --argjson i "$i" '.items[$i].current // ""' "$items")
    [[ -n "$current" ]] || continue
    mkdir -p "$root/$(dirname "$file")"
    cp "$current" "$root/$file"
  done
  sgit add -A
  sgit commit --quiet --allow-empty -m "current"
  base=$(sgit rev-parse HEAD)

  headers="[]"
  for ((i = 0; i < n; i++)); do
    file=$(jq -r --argjson i "$i" '.items[$i].file' "$items")
    proposed=$(jq -r --argjson i "$i" '.items[$i].proposed' "$items")
    mkdir -p "$root/$(dirname "$file")" "$dir/seeded/$(dirname "$file")"
    cp "$proposed" "$root/$file"
    cp "$proposed" "$dir/seeded/$file"
    if has_header "$proposed"; then headers=$(jq -c --arg f "$file" '. + [$f]' <<<"$headers"); fi
  done

  # Each note's anchor. revdiff draws a note under its line, so a note about
  # line N sits on line N-1, and its marker has to match that line's side of the
  # diff or revdiff drops it.
  anchors="$dir/anchors.tsv"; : > "$anchors"
  errors=()
  while IFS=$'\x1f' read -r iid k file line; do
    [[ -n "$iid" ]] || continue
    if [[ -z "$line" ]]; then
      printf '%s\t%s\tfile\t\n' "$file" "$k" >> "$anchors"; continue
    fi
    count=$(awk 'END { print NR }' "$root/$file")
    (( line >= 1 && line <= count )) || { errors+=("item $iid $file:$line: not a line of the proposed text ($count lines)"); continue; }
    at=$(( line > 1 ? line - 1 : 1 ))
    if sgit cat-file -e "$base:$file" 2>/dev/null; then
      added=$(sgit -c core.quotePath=false diff -U0 --no-color "$base" -- "$file" | awk -v L="$at" '
        /^@@ / { split($3, n, ","); nl = substr(n[1], 2) + 0; next }
        /^\+\+\+ / { next }
        /^\+/ { if (nl == L) hit = 1; nl++ }
        END { print hit + 0 }')
      marker=$([[ "$added" == 1 ]] && echo "+" || echo " ")
    else
      marker="+"
    fi
    printf '%s\t%s\t%s\t%s\n' "$file" "$k" "$marker" "$at" >> "$anchors"
  done < <(jq -r '.items[] | .id as $id | .file as $f | (.notes // []) | to_entries[]
    | [($id|tostring), (.key|tostring), $f, ((.value.line // "")|tostring)] | join("\u001f")' "$items")
  if [[ ${#errors[@]} -gt 0 ]]; then
    for e in "${errors[@]}"; do echo "BATCH_ERROR=$e"; done
    rm -rf "$dir"
    exit 65
  fi

  # Each item opens with a note naming it, since a compact diff can hide an
  # unchanged title. revdiff keeps one file-level note per file, so the item's
  # own file-level notes are folded in under it.
  titles="{}"
  for ((i = 0; i < n; i++)); do
    file=$(jq -r --argjson i "$i" '.items[$i].file' "$items")
    proposed=$(jq -r --argjson i "$i" '.items[$i].proposed' "$items")
    t=""
    if has_header "$proposed"; then
      t=$(awk '$0 == "---" { exit } /^title: / { sub(/^title: /, ""); print; exit }' "$proposed")
    fi
    titles=$(jq -c --arg f "$file" --arg t "$t" '. + {($f): $t}' <<<"$titles")
  done
  jq -n --slurpfile it "$items" --rawfile a "$anchors" --argjson titles "$titles" '
    ($a | split("\n") | map(select(length > 0) | split("\t")
      | {file:.[0], k:(.[1]|tonumber), marker:.[2], line:(if .[3] == "" then null else (.[3]|tonumber) end)})) as $anchors
    | [$it[0].items[] as $i
       | ($i.notes // []) as $notes
       | ([$notes[] | select(.line == null) | .body]) as $filenotes
       | ("\(if ($i.current // "") == "" then "✨" else "🗒" end) \($i.id | tostring | if startswith("#") then . else "#" + . end) · \(if $titles[$i.file] != "" then $titles[$i.file] else ($i.summary // $i.file) end)"
          + (if $i.url then "\n🔗 \($i.url)" else "" end)) as $head
       | {id:($i.id|tostring), file:$i.file, line:null, marker:"file", side:"new",
          body:([$head] + $filenotes | join("\n\n"))},
         ($notes | to_entries[] | select(.value.line != null) as $n
          | ($anchors | map(select(.file == $i.file and .k == $n.key)) | first) as $s
          | {id:($i.id|tostring), file:$i.file, line:$s.line, marker:$s.marker,
             side:(if $s.marker == "-" then "old" else "new" end), body:$n.value.body})]
  ' > "$dir/notes.json"
  jq -r '.[] | (if .marker == "file" then "## \(.file) (file-level)" else "## \(.file):\(.line) (\(.marker))" end)
         + "\n" + (.body | gsub("\n## "; "\n ## ")) + "\n"' "$dir/notes.json" > "$dir/notes.md"

  {
    printf '# %s\n\n' "${title:-Batch edit}"
    cat <<'EOF'
Each row is one item, and each item is a file in this tree: its current text on
the left, the proposed text on the right. Notes in the diff are context for this
review and go nowhere else. Quit with `q` when you're done; an item you leave as
it is goes out as proposed. To change one, edit its file (`e` opens it in your
editor) or leave a note on it or on its row. To drop one, delete its row.

| # | file | change | web |
|---|---|---|---|
EOF
    jq -r '.items[] | "| \(.id | tostring | gsub("\\|"; "\\|")) | \(.file) | \(if .current then "" else "new: " end)\(.summary // "" | gsub("\\|"; "\\|") | gsub("\n"; " ")) | \(if .url then "[link](\(.url))" else "" end) |"' "$items"
  } > "$root/$TABLE"
  cp "$root/$TABLE" "$dir/table.seeded"

  jq -n --arg base "$base" --argjson headers "$headers" --slurpfile it "$items" \
    '{base:$base, headers:$headers, items:[$it[0].items[] | {id:(.id|tostring), file, url:(.url // null), new:(.current == null or .current == "")}]}' \
    > "$dir/batch.json"
  trap - ERR
  echo "BATCH_DIR=$dir"
  echo "BATCH_ROOT=$root"
  echo "BATCH_BASE=$base"
  echo "NOTES=$dir/notes.md"
  echo "TABLE=$root/$TABLE"
  echo "ITEM_COUNT=$n"
  echo "NOTE_COUNT=$(jq length "$dir/notes.json")"
  ;;

read)
  need_dir
  [[ -n "$returned" && -r "$returned" ]] || { echo "batch-edit.sh read needs the --returned file the review wrote" >&2; exit 64; }
  out="$dir/out"; rm -rf "$out"; mkdir -p "$out"
  table_lines=""
  [[ -f "$root/$TABLE" ]] && table_lines=$(cat "$root/$TABLE")

  # Each item's final text, split into its header fields and body where it was
  # seeded with a header.
  texts="[]"
  n=$(jq '.items | length' "$dir/batch.json")
  for ((i = 0; i < n; i++)); do
    file=$(jq -r --argjson i "$i" '.items[$i].file' "$dir/batch.json")
    final="$root/$file"
    present=1 edited=0 fields="null" body="" ferr=""
    if [[ ! -f "$final" ]]; then
      present=0
    else
      cmp -s "$final" "$dir/seeded/$file" || edited=1
      body="$out/$i.body"
      if jq -e --arg f "$file" '.headers | index($f)' "$dir/batch.json" >/dev/null; then
        if has_header "$final"; then
          fields=$(awk '$0 == "---" { exit } { k = $0; sub(/:.*/, "", k); v = substr($0, length(k) + 2); sub(/^ /, "", v); print k "\t" v }' "$final" \
            | jq -Rn '[inputs | split("\t") | {key:.[0], value:(.[1:] | join("\t"))}] | from_entries')
          awk 'h == 2 { print; next } h == 1 { if ($0 != "") { h = 2; print }; next } $0 == "---" { h = 1 }' "$final" > "$body"
        else
          ferr="the header block above the --- line no longer parses"
          cp "$final" "$body"
        fi
      else
        cp "$final" "$body"
      fi
    fi
    texts=$(jq -c --arg f "$file" --argjson p "$present" --argjson e "$edited" --argjson fl "$fields" \
      --arg b "$body" --arg ferr "$ferr" \
      '. + [{file:$f, present:($p == 1), edited:($e == 1), fields:$fl,
             body:(if $b == "" then null else $b end), fieldsError:(if $ferr == "" then null else $ferr end)}]' <<<"$texts")
  done

  # A row's id is its first cell, unescaped. The header row's is `#` and the
  # separator row has none, so neither is an item's row.
  jq -n \
    --slurpfile batch "$dir/batch.json" --slurpfile seeded "$dir/notes.json" --slurpfile ret "$returned" \
    --argjson texts "$texts" --rawfile table0 "$dir/table.seeded" \
    --arg table "$table_lines" --arg tname "$TABLE" '
    def rowid: select(test("^\\|[-|: ]+$") | not)
      | capture("^\\|(?<c>(?:\\\\.|[^|\\\\])*)\\|").c
      | sub("^\\s+"; "") | sub("\\s+$"; "") | gsub("\\\\\\|"; "|") | select(. != "#");
    def rowmap: split("\n") | map((rowid? // null) as $id | select($id != null) | {id:$id, row:.});
    def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    ($table0 | rowmap) as $r0 | ($table | rowmap) as $r1
    | ($table | split("\n")) as $tl
    | ($ret[0] // []) as $all
    | ($all | map(select(.file == $tname)
        | . + {rowId: ((.startLine // 0) as $n | if $n > 0 then (($tl[$n-1] // "") | (rowid? // null)) else null end)})) as $tnotes
    | ($seeded[0] | map({file, line, b:(.body | norm)})) as $s
    | ($batch[0].items | map(.file)) as $files
    | {items: [$batch[0].items[] as $i
        | ($texts | map(select(.file == $i.file)) | first) as $t
        | ($r0 | map(select(.id == $i.id)) | first | .row) as $was
        | ($r1 | map(select(.id == $i.id)) | first | .row) as $now
        | [$all[] | select(.file == $i.file)
           | select(((.startLine // null) as $l | (.body | norm) as $b | .file as $f
                     | $s | any(.file == $f and .line == $l and .b == $b)) | not)
           | .body] as $notes
        | ($tnotes | map(select(.rowId == $i.id)) | map(.body)) as $rownotes
        | {id:$i.id, file:$i.file, url:$i.url, new:$i.new, row:$now, notes:$notes, rowNotes:$rownotes,
           rowEdited:($now != null and $was != null and (($now|norm) != ($was|norm))),
           edited:$t.edited, fields:$t.fields, body:$t.body, fieldsError:$t.fieldsError}
        | .decision = (if .row == null or ($t.present | not) then "drop"
                       elif (.notes | length > 0) or (.rowNotes | length > 0) or .rowEdited or .fieldsError then "change"
                       elif .edited then "edited"
                       else "keep" end)],
       general: ([$tnotes[] | select(.rowId == null) | .body]
                 + [$all[] | .file as $f | select($f == null or (($f != $tname) and (($files | index($f)) == null))) | .body])}
  ' > "$dir/read.json"
  echo "BATCH_READ=$dir/read.json"
  jq -r '"KEEP=\([.items[]|select(.decision=="keep")|.id]|join(","))",
         "EDITED=\([.items[]|select(.decision=="edited")|.id]|join(","))",
         "CHANGE=\([.items[]|select(.decision=="change")|.id]|join(","))",
         "DROP=\([.items[]|select(.decision=="drop")|.id]|join(","))",
         "GENERAL=\(.general|length)"' "$dir/read.json"
  ;;

finish)
  need_dir
  rm -rf "$dir"
  echo "FINISHED=1"
  ;;

*) echo "batch-edit.sh: unknown command: $cmd" >&2; exit 64 ;;
esac
