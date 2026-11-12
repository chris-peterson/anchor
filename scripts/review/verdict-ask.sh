#!/usr/bin/env bash
# Ask for the verdict a `diff` review closed without, in the pane the review ran
# in (DIFF-49). The launch script runs this once the tool exits:
#
#   verdict-ask.sh <tool> <out_file> <preload_file> <choice_file> <palette_file> <rc>
#
# Where the tool's adapter reads the review as untouched (`diff_tool_untouched`),
# a centered box offers Approve, Reject, and Go back, and the answer goes to
# <choice_file> as `approve` or `reject`, for the mode adapter
# to read as the Review box choice it stands for. Exits 0 for Go back, which
# the launch script reads as "run the review again", and 1 otherwise.
#
# <palette_file> holds the tool's resolved colors as `key = #rrggbb` lines
# (revdiff's --dump-theme), so the box draws in the theme the review just did.
#
# `Z` approves and `Q` rejects, the second half of an `edit` review's `ZZ`
# and `ZQ` in Helix or Vim, which with the review's `Z` bound to quit work here
# too, and `z` and `q` answer as well once the box is up. Esc goes back into
# the review. Focus starts on Go back and Enter acts
# only on the focused button, and of the keys typed before the box drew only a
# lone `Z` or `Q` is kept, so a second `q` or a stray Enter never approves
# anything.
set -u

tool="$1" out_file="$2" preload_file="$3" choice_file="$4" palette_file="$5" rc="$6"

# shellcheck source=tools/revdiff.sh
source "$(dirname "${BASH_SOURCE[0]}")/tools/$tool.sh"
diff_tool_untouched "$rc" "$out_file" "$preload_file" || exit 1

ESC=$'\e'
RESET="${ESC}[0m"

# The palette's color for <key> as an SGR parameter, for `38;` (foreground) or
# `48;` (background) to lead; empty for a key the palette doesn't carry.
color() {
  local hex
  hex=$(sed -n "s/^$1 *= *#\([0-9a-fA-F]\{6\}\)$/\1/p" "$palette_file" 2>/dev/null | head -1)
  [[ -n "$hex" ]] || return 0
  printf '2;%d;%d;%d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}
sgr() { [[ -z "$2" ]] || printf '%s[%s;%sm' "$ESC" "$1" "$2"; }

c_panel=$(sgr 48 "$(color color-diff-bg)")
c_normal=$(sgr 38 "$(color color-normal)")
c_accent=$(sgr 38 "$(color color-accent)")
c_muted=$(sgr 38 "$(color color-muted)")
c_key=$(sgr 38 "$(color color-annotation)")
c_sel="$(sgr 38 "$(color color-selected-fg)")$(sgr 48 "$(color color-selected-bg)")"
c_chip="$(sgr 38 "$(color color-normal)")$(sgr 48 "$(color color-border)")"
base="${RESET}${c_panel}"

labels=("Approve" "Reject" "Go back")
keys=(Z Q Esc)
values=(approve reject rereview)
focus=2
w=60 h=9

# Print <text> at <row> <col>; <text> carries its own styling.
at() { printf '%s[%d;%dH%s' "$ESC" $(($1 + 1)) $(($2 + 1)) "$3"; }

button() {
  local i="$1" style key
  if (( i == focus )); then
    style="${RESET}${c_sel}${ESC}[1m" key="$style"
  else
    style="${RESET}${c_chip}" key="${style}${c_key}"
  fi
  printf '%s %s%s %s %s' "$key" "${keys[$i]}" "$style" "${labels[$i]}" "$base"
}

draw() {
  local rows cols top left i inner=$((w - 2)) hr blank btns hint
  rows=$(tput lines) cols=$(tput cols)
  top=$(( (rows - h) / 2 )) left=$(( (cols - w) / 2 ))
  (( top >= 0 )) || top=0
  (( left >= 0 )) || left=0
  hr=$(printf '%*s' "$inner" '' | sed 's/ /─/g')
  blank=$(printf '%*s' "$inner" '')

  printf '%s%s[2J' "$base" "$ESC"
  at "$top" "$left" "${base}${c_accent}╭${hr}╮"
  for ((i = 1; i < h - 1; i++)); do
    at $((top + i)) "$left" "${base}${c_accent}│${c_normal}${blank}${c_accent}│"
  done
  at $((top + h - 1)) "$left" "${base}${c_accent}╰${hr}╯"

  at $((top + 2)) $((left + 4)) "${base}${c_accent}${ESC}[1mNo verdict chosen${base}"
  at $((top + 3)) $((left + 4)) "${base}${c_normal}The review closed without one."

  btns=""
  for i in 0 1 2; do btns+="$(button "$i")   "; done
  at $((top + 5)) $((left + (w - 40) / 2)) "$btns"

  hint="${c_key}←→${c_muted} move  ${c_key}enter${c_muted} choose"
  at $((top + 7)) $((left + (w - 21) / 2)) "${base}${hint}"
}

finish() {
  if [[ "$1" == rereview ]]; then
    rm -f "$choice_file"
    exit 0
  fi
  printf '%s\n' "$1" > "$choice_file"
  exit 1
}

trap 'printf "%s" "$RESET"; tput cnorm; tput clear' EXIT
trap draw WINCH
tput civis
early="" key=""
if [[ -t 0 ]]; then while IFS= read -rsn1 -t 0.05 key; do early+="$key"; done; fi
case "$early" in
  Z) finish approve ;;
  Q) finish reject ;;
esac
draw
while :; do
  IFS= read -rsn1 key || finish dismiss
  case "$key" in
    Z|z) finish approve ;;
    Q|q) finish reject ;;
    "")  finish "${values[$focus]}" ;;
    $'\t') focus=$(( (focus + 1) % 3 )); draw ;;
    $'\e')
      IFS= read -rsn2 -t 0.02 rest || rest=""
      case "$rest" in
        "[C") focus=$(( (focus + 1) % 3 )); draw ;;
        "[D") focus=$(( (focus + 2) % 3 )); draw ;;
        "")   finish rereview ;;
      esac ;;
  esac
done
