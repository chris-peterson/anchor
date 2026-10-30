#!/usr/bin/env bash
# Functional test for scripts/review-status.sh and the section it keeps
# (scripts/lib/review-status.sh).
#
# Drives the real script against a scratch repo and stub `gh` / `glab` that serve
# the CR from a fixture and capture the description written back, so what is
# asserted is what that description records: which commits a round counted, a
# rebase keeping a commit's rounds, an amend starting them over, and someone
# else's CR left alone.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status_sh="$here/../scripts/review-status.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }
val()  { sed -n "s/^$1=//p" <<<"$out"; }

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-review-status-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
fx="$work/fx"
mkdir -p "$bin" "$fx"
export FX="$fx"

# `pr edit --body-file` and the MR PUT both land in $FX/written.md, which the
# next `pr view` / `mr view` then serves, as the forge would.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "pr view") jq --rawfile b "$FX/body.md" '.body = $b' "$FX/pr.json" ;;
  "pr edit") while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && cp "$2" "$FX/body.md"; shift; done ;;
  "api user") echo '{"login":"me"}' ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 1 ;;
esac
EOF
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "mr view")  jq --rawfile b "$FX/body.md" '.description = $b' "$FX/mr.json" ;;
  "api user") echo '{"username":"me"}' ;;
  "api -X")   for a in "$@"; do [[ "$a" == description=@* ]] && cp "${a#description=@}" "$FX/body.md"; done ;;
  *) echo "stub glab: unhandled: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"

new_repo() {
  repo="$work/$1"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" remote add origin "$2"
  printf 'seed\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m seed
  git -C "$repo" checkout --quiet -b feature
  for f in a b c; do
    printf '%s\n' "$f" > "$repo/$f.txt"
    git -C "$repo" add "$f.txt"
    git -C "$repo" commit --quiet -m "add $f"
  done
}

run() {
  out=""; status=0
  out="$(bash "$status_sh" record --repo "$repo" "$@" 2>&1)" || status=$?
}

# shellcheck source=../scripts/lib/review-status.sh
source "$here/../scripts/lib/review-status.sh"

# The description's record of each commit in main..HEAD, oldest first.
recorded() { (cd "$repo" && review_status_rows "$(review_status_data "$fx/body.md")" "$main" HEAD); }
# Each commit as "<short sha> <rounds> [<reviewed by>] <result>".
table() { recorded | jq -r '.[] | "\(.sha[0:8]) \(.rounds) [\(.by | join(", "))] \(if .rounds == 0 then "not reviewed" else .result end)"'; }
# One commit's notes, joined.
notes_of() { recorded | jq -r --arg s "$1" '.[] | select(.sha[0:8] == $s) | .notes | join("; ")'; }
sections() { grep -c '^<!-- anchor:review-status {' "$fx/body.md"; }
sha8() { git -C "$repo" rev-parse --short=8 "$1"; }

# --- GitHub -----------------------------------------------------------------

new_repo gh "https://github.com/acme/widget.git"
main=$(git -C "$repo" rev-parse main)
gh_pr() {
  jq -n --arg b "$main" --arg h "$(git -C "$repo" rev-parse HEAD)" --arg a "${1:-me}" --argjson d "${2:-false}" \
    '{author: {login: $a}, baseRefOid: $b, headRefOid: $h, isDraft: $d}' > "$fx/pr.json"
}
gh_pr
printf 'Why this change exists.\n' > "$fx/body.md"

run --cr 7 --base "$main" --head HEAD --result approved
[[ "$status" == 0 ]] || fail "first record exited $status: $out"
[[ "$(val STATUS_RECORDED)" == 3 ]] || fail "a whole-CR round counts every commit: $out"
[[ "$(val STATUS_UNREVIEWED)" == 0 ]] || fail "nothing should be left unreviewed: $out"
head -n 1 "$fx/body.md" | grep -qx 'Why this change exists.' || fail "the description above the section should survive: $(cat "$fx/body.md")"
[[ "$(sections)" == 1 && "$(tail -n 1 "$fx/body.md")" == '<!-- anchor:review-status {'* ]] \
  || fail "the section should be appended as one comment line: $(cat "$fx/body.md")"
[[ "$(table)" == "$(sha8 HEAD~2) 1 [me] approved
$(sha8 HEAD~1) 1 [me] approved
$(sha8 HEAD) 1 [me] approved" ]] || fail "first round table:"$'\n'"$(table)"
ok "a round over the whole CR gives every commit its first round"

run --cr 7 --base HEAD~1 --head HEAD --result changes-requested
[[ "$status" == 0 ]] || fail "second record exited $status: $out"
[[ "$(table)" == "$(sha8 HEAD~2) 1 [me] approved
$(sha8 HEAD~1) 1 [me] approved
$(sha8 HEAD) 2 [me] changes-requested" ]] || fail "second round table:"$'\n'"$(table)"
[[ "$(sections)" == 1 ]] || fail "the section should be replaced, not repeated: $(cat "$fx/body.md")"
ok "a round over one commit counts only that commit, and replaces the section"

run --cr 7 --base HEAD~2 --head HEAD --result approved --note "declined to refactor the uploader" --note 'kept a|b --> as is'
[[ "$status" == 0 ]] || fail "a round with notes exited $status: $out"
[[ "$(notes_of "$(sha8 HEAD)")" == 'declined to refactor the uploader; kept a|b --> as is' ]] \
  || fail "the notes ride on the newest commit the round reviewed: $(cat "$fx/body.md")"
[[ -z "$(notes_of "$(sha8 HEAD~1)")" ]] || fail "an older commit in the round gets no note: $(cat "$fx/body.md")"
data_line=$(grep '^<!-- anchor:review-status ' "$fx/body.md")
[[ "$data_line" == *' -->' && "${data_line%' -->'}" != *'-->'* ]] \
  || fail "a note's --> can't close the data comment early: $(cat "$fx/body.md")"
[[ "$(review_status_notes "$(review_status_data "$fx/body.md")")" == '["declined to refactor the uploader","kept a|b --> as is"]' ]] \
  || fail "the notes read back as written: $(review_status_data "$fx/body.md")"
ok "a round's notes ride on its newest commit, and read back whole"

# A new commit on top is recorded at no rounds until a review covers it.
printf 'd\n' > "$repo/d.txt"
git -C "$repo" add d.txt
git -C "$repo" commit --quiet -m "add d"
printf 'after the section\n' >> "$fx/body.md"
run --cr 7 --base HEAD~1 --head HEAD --result approved
[[ "$(table | tail -n 1)" == "$(sha8 HEAD) 1 [me] approved" ]] || fail "the new commit should get its round:"$'\n'"$(table)"
sed -n '/^<!-- anchor:review-status {/,$p' "$fx/body.md" | grep -qx 'after the section' || fail "text after the section should survive: $(cat "$fx/body.md")"
ok "a commit added later is recorded on its own, and text after the section survives"

# Rebase onto a moved main: the shas change and the patches don't.
git -C "$repo" checkout --quiet main
printf 'other\n' > "$repo/other.txt"
git -C "$repo" add other.txt
git -C "$repo" commit --quiet -m other
main=$(git -C "$repo" rev-parse main)
git -C "$repo" checkout --quiet feature
git -C "$repo" rebase --quiet main
# Amend the newest commit's change, so it is no longer the change that was reviewed.
printf 'd2\n' > "$repo/d.txt"
git -C "$repo" commit --quiet -a --amend --no-edit
gh_pr
run --cr 7 --base HEAD~2 --head HEAD~1 --result approved
[[ "$(table)" == "$(sha8 HEAD~3) 1 [me] approved
$(sha8 HEAD~2) 2 [me] approved
$(sha8 HEAD~1) 4 [me] approved
$(sha8 HEAD) 0 [] not reviewed" ]] || fail "after rebase and amend:"$'\n'"$(table)"
[[ "$(val STATUS_UNREVIEWED)" == 1 ]] || fail "the amended commit is unreviewed: $out"
ok "a rebased commit keeps its rounds by patch-id; an amended one starts at none"

# Someone else's CR: written to only where it already has the section and is
# out of draft.
before=$(cat "$fx/body.md")
gh_pr someone-else true
run --cr 7 --base "$main" --head HEAD --result approved
[[ "$status" == 0 && "$(val STATUS_SKIPPED)" == draft && "$(val STATUS_RECORDED)" == 0 ]] \
  || fail "someone else's draft should be skipped: $out"
[[ "$(cat "$fx/body.md")" == "$before" ]] || fail "someone else's draft should be untouched"
gh_pr someone-else
run --cr 7 --base HEAD~1 --head HEAD --result approved
[[ "$status" == 0 && "$(val STATUS_RECORDED)" == 1 ]] || fail "someone else's ready CR with the section should be recorded: $out"
[[ "$(table | tail -n 1)" == "$(sha8 HEAD) 1 [me] approved" ]] || fail "someone else's CR table:"$'\n'"$(table)"
printf 'Why.\n' > "$fx/body.md"
run --cr 7 --base "$main" --head HEAD --result approved
[[ "$status" == 0 && "$(val STATUS_SKIPPED)" == no-section ]] || fail "someone else's CR without the section should be skipped: $out"
[[ "$(cat "$fx/body.md")" == "Why." ]] || fail "a description without the section should be untouched"
ok "someone else's CR is written to only where it has the section and is out of draft"

gh_pr
run --cr 7 --base "$main" --head HEAD --result lgtm
[[ "$status" == 64 ]] || fail "an unknown result should exit 64, got $status: $out"
run --cr 7 --base HEAD --head "$main" --result approved
[[ "$status" == 65 ]] || fail "a base that isn't an ancestor of head should exit 65, got $status: $out"
ok "a bad result or range is refused"

# --- GitLab -----------------------------------------------------------------

new_repo gl "https://gitlab.com/acme/widget.git"
main=$(git -C "$repo" rev-parse main)
jq -n --arg b "$main" '{author: {username: "me"}, diff_refs: {base_sha: $b}}' > "$fx/mr.json"
: > "$fx/body.md"
run --cr 12 --base "$main" --head HEAD --result approved
[[ "$status" == 0 ]] || fail "gitlab record exited $status: $out"
head -n 1 "$fx/body.md" | grep -q '^<!-- anchor:review-status {' || fail "an empty description should get just the section: $(cat "$fx/body.md")"
[[ "$(table | wc -l | tr -d ' ')" == 3 ]] || fail "gitlab table:"$'\n'"$(table)"
ok "gitlab: the section is written through the MR API"

# A second reviewer joins the list once; the same reviewer again doesn't repeat.
by=$(cd "$repo" && d=$(review_status_add '{}' "$main" HEAD approved me) \
  && d=$(review_status_add "$d" "$main" HEAD approved ana) \
  && d=$(review_status_add "$d" "$main" HEAD approved me) \
  && review_status_rows "$d" "$main" HEAD | jq -c '[.[0].rounds, .[0].by]')
[[ "$by" == '[3,["me","ana"]]' ]] || fail "reviewers should list each one once, in order: $by"
ok "each reviewer is listed once, in the order they first reviewed"
