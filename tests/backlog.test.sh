#!/usr/bin/env bash
# Functional test for scripts/backlog.sh.
#
# Drives the real script against stub `gh` / `glab` that serve issues, open and
# merged CRs, and branches, in a scratch checkout whose local branches carry
# commit dates the cases depend on. What is asserted is the stage each issue
# lands in, the CR or branch it is tied to, its flags, the order, and the scope
# flags each forge is handed.
#
# The load-bearing cases are the links that must *not* form: a merged CR that
# only mentioned an issue is not its end, `release-2` is not issue 2's branch,
# and `prefixes #19` closes nothing. A false link moves an unstarted issue to the
# top of the list as if it were in review, which is the error this script exists
# to stop the skill making.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backlog_sh="$here/../scripts/backlog.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  echo "PASS"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-backlog-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin" "$work/fx"

# Each stub serves fixtures from $FX and logs every call to $CALL_LOG.
# $FAIL_AUTH makes every call fail as an expired token would; $OLD_GH makes gh
# refuse closingIssuesReferences, as a gh that predates the field does.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$CALL_LOG"
[[ -z "${FAIL_AUTH:-}" ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
case "$*" in
  "api user") echo '{"login":"me"}' ;;
  "issue list"*) cat "$FX/gh-issues.json" ;;
  "pr list"*)
    if [[ -n "${OLD_GH:-}" && "$*" == *closingIssuesReferences* ]]; then
      echo 'Unknown JSON field: "closingIssuesReferences"' >&2; exit 1
    fi
    f="$FX/gh-open.json"; [[ "$*" != *"--state merged"* ]] || f="$FX/gh-merged.json"
    if [[ -n "${NO_CRS:-}" ]]; then echo '[]'; exit 0; fi
    if [[ -n "${OLD_GH:-}" ]]; then jq 'map(del(.closingIssuesReferences))' "$f"; else cat "$f"; fi ;;
  "api repos/"*"/branches"*) echo '[{"name":"main"},{"name":"12-remote-only"}]' ;;
  *) echo "stub gh: unhandled command: $*" >&2; exit 1 ;;
esac
EOF

cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "glab $*" >> "$CALL_LOG"
[[ -z "${FAIL_AUTH:-}" ]] || { echo "401 Unauthorized" >&2; exit 1; }
case "$*" in
  "api user") echo '{"username":"me"}' ;;
  "issue list"*) cat "$FX/gl-issues.json" ;;
  "mr list"*"--merged"*) cat "$FX/gl-merged.json" ;;
  "mr list"*) cat "$FX/gl-open.json" ;;
  *) echo "stub glab: unhandled command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$bin/gh" "$bin/glab"
PATH="$bin:$PATH"
FX="$work/fx"
CALL_LOG="$work/calls.log"
ANCHOR_TODAY=2026-06-01
export PATH FX CALL_LOG ANCHOR_TODAY

# --- fixtures ----------------------------------------------------------------

cat > "$FX/gh-issues.json" <<'EOF'
[
  {"number":10,"title":"Closed by a draft PR","url":"u/10","state":"OPEN","updatedAt":"2026-05-01T00:00:00Z","milestone":null,"assignees":[]},
  {"number":11,"title":"Referenced by an open PR","url":"u/11","state":"OPEN","updatedAt":"2026-05-02T00:00:00Z","milestone":null,"assignees":[]},
  {"number":12,"title":"Has a fresh branch","url":"u/12","state":"OPEN","updatedAt":"2026-05-03T00:00:00Z","milestone":null,"assignees":[]},
  {"number":13,"title":"Has an old branch","url":"u/13","state":"OPEN","updatedAt":"2026-05-20T00:00:00Z","milestone":null,"assignees":[]},
  {"number":14,"title":"Closed by a merged PR","url":"u/14","state":"OPEN","updatedAt":"2026-05-04T00:00:00Z","milestone":null,"assignees":[]},
  {"number":15,"title":"Mentioned by a merged PR","url":"u/15","state":"OPEN","updatedAt":"2026-05-05T00:00:00Z","milestone":null,"assignees":[]},
  {"number":16,"title":"Past its milestone","url":"u/16","state":"OPEN","updatedAt":"2026-05-06T00:00:00Z","milestone":{"title":"1.0","dueOn":"2026-05-15T00:00:00Z"},"assignees":[]},
  {"number":17,"title":"Nobody has touched this","url":"u/17","state":"OPEN","updatedAt":"2026-01-01T00:00:00Z","milestone":null,"assignees":[]},
  {"number":18,"title":"nobody has touched THIS","url":"u/18","state":"OPEN","updatedAt":"2026-05-07T00:00:00Z","milestone":null,"assignees":[]},
  {"number":2,"title":"Not the release branch","url":"u/2","state":"OPEN","updatedAt":"2026-05-08T00:00:00Z","milestone":null,"assignees":[]},
  {"number":19,"title":"Not closed by a prefix","url":"u/19","state":"OPEN","updatedAt":"2026-05-09T00:00:00Z","milestone":{"title":"1.1","dueOn":"2026-07-01T00:00:00Z"},"assignees":[]},
  {"number":30,"title":"My reviewed draft","url":"u/30","state":"OPEN","updatedAt":"2026-05-11T00:00:00Z","milestone":null,"assignees":[]},
  {"number":31,"title":"Their CR, reviewed before a push","url":"u/31","state":"OPEN","updatedAt":"2026-05-12T00:00:00Z","milestone":null,"assignees":[]},
  {"number":32,"title":"Their CR, reviewed at head","url":"u/32","state":"OPEN","updatedAt":"2026-05-13T00:00:00Z","milestone":null,"assignees":[]}
]
EOF

# Review status sections (scripts/lib/review-status.sh): a round on the head
# commit is `reviewed`; one on an earlier commit only is `partial`.
cat > "$FX/gh-open.json" <<'EOF'
[
  {"number":20,"title":"Draft for ten","url":"p/20","body":"","headRefName":"some-work","headRefOid":"a20","isDraft":true,
   "author":{"login":"me"},"updatedAt":"2026-05-10T00:00:00Z","closingIssuesReferences":[{"number":10}]},
  {"number":21,"title":"Part of eleven","url":"p/21","body":"Refs: #11","headRefName":"other","headRefOid":"a21","isDraft":false,
   "author":{"login":"them"},"updatedAt":"2026-05-09T00:00:00Z","closingIssuesReferences":[]},
  {"number":24,"title":"Untracked work","url":"p/24","headRefName":"untracked","headRefOid":"a24full","isDraft":false,
   "body":"No issue here; prefixes #19 too\n<!-- anchor:review-status\n{\n\"a24\": {\"patch\":\"x\",\"rounds\":1,\"by\":[\"me\"]}\n}\n-->",
   "author":{"login":"me"},"updatedAt":"2026-05-08T00:00:00Z","closingIssuesReferences":[]},
  {"number":25,"title":"Someone else's untracked","url":"p/25","body":"","headRefName":"theirs","headRefOid":"a25","isDraft":false,
   "author":{"login":"them"},"updatedAt":"2026-05-10T00:00:00Z","closingIssuesReferences":[]},
  {"number":26,"title":"Reviewed draft","url":"p/26","headRefName":"mine-26","headRefOid":"a26","isDraft":true,
   "body":"Closes #30\n<!-- anchor:review-status\n{\n\"a26\": {\"rounds\":2,\"by\":[\"me\"]}\n}\n-->",
   "author":{"login":"me"},"updatedAt":"2026-05-11T00:00:00Z","closingIssuesReferences":[]},
  {"number":27,"title":"Pushed since my review","url":"p/27","headRefName":"t-27","headRefOid":"b27","isDraft":false,
   "body":"Closes #31\n<!-- anchor:review-status\n{\n\"a27\": {\"rounds\":1,\"by\":[\"me\"]},\n\"b27\": {\"committed\":{\"by\":[\"them\"]}}\n}\n-->",
   "author":{"login":"them"},"updatedAt":"2026-05-12T00:00:00Z","closingIssuesReferences":[]},
  {"number":28,"title":"Reviewed by me at head","url":"p/28","headRefName":"t-28","headRefOid":"a28","isDraft":false,
   "body":"Closes #32\n<!-- anchor:review-status {\"a28\": {\"rounds\":1,\"by\":[\"them\",\"me\"]}} -->",
   "author":{"login":"them"},"updatedAt":"2026-05-13T00:00:00Z","closingIssuesReferences":[]}
]
EOF

cat > "$FX/gh-merged.json" <<'EOF'
[
  {"number":22,"title":"Landed fourteen","url":"p/22","body":"Closes #14","headRefName":"14-landed","isDraft":false,
   "author":{"login":"me"},"updatedAt":"2026-04-01T00:00:00Z","closingIssuesReferences":[]},
  {"number":23,"title":"Part of fifteen","url":"p/23","body":"Refs #15","headRefName":"x","isDraft":false,
   "author":{"login":"me"},"updatedAt":"2026-04-01T00:00:00Z","closingIssuesReferences":[]}
]
EOF

cat > "$FX/gl-issues.json" <<'EOF'
[
  {"iid":5,"title":"Closed by a draft MR","web_url":"g/5","state":"opened","updated_at":"2026-05-01T00:00:00.000Z","due_date":null,"milestone":null,"assignees":[{"username":"me"}]},
  {"iid":6,"title":"MR from the issue's branch","web_url":"g/6","state":"opened","updated_at":"2026-05-02T00:00:00.000Z","due_date":null,"milestone":null,"assignees":[]},
  {"iid":8,"title":"Merged, still open","web_url":"g/8","state":"opened","updated_at":"2026-05-03T00:00:00.000Z","due_date":null,"milestone":{"due_date":"2026-05-20"},"assignees":[{"username":"me"}]},
  {"iid":9,"title":"Due soon, unstarted","web_url":"g/9","state":"opened","updated_at":"2026-05-04T00:00:00.000Z","due_date":"2026-06-10","milestone":null,"assignees":[{"username":"me"}]}
]
EOF

cat > "$FX/gl-open.json" <<'EOF'
[
  {"iid":7,"title":"Draft: five","web_url":"m/7","description":"Closes #5","source_branch":"five","draft":true,
   "author":{"username":"me"},"updated_at":"2026-05-10T00:00:00.000Z"},
  {"iid":10,"title":"Six","web_url":"m/10","source_branch":"6-mr-from-issue","sha":"c10","draft":false,
   "description":"<!-- anchor:review-status\n{\n\"c10\": {\"rounds\":1,\"by\":[\"me\"]}\n}\n-->",
   "author":{"username":"them"},"updated_at":"2026-05-10T00:00:00.000Z"}
]
EOF

cat > "$FX/gl-merged.json" <<'EOF'
[
  {"iid":11,"title":"Eight","web_url":"m/11","description":"Fixes #8","source_branch":"eight","draft":false,
   "author":{"username":"me"},"updated_at":"2026-04-10T00:00:00.000Z"}
]
EOF

# --- checkouts ----------------------------------------------------------------

mkrepo() {
  local dir="$1" url="$2"
  git init --quiet -b main "$dir"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" -c user.name=t -c user.email=t@e commit --quiet --allow-empty -m root
}
# branch <repo> <name> <committer date>
branch() {
  git -C "$1" checkout --quiet -b "$2" main
  GIT_COMMITTER_DATE="$3" GIT_AUTHOR_DATE="$3" \
    git -C "$1" -c user.name=t -c user.email=t@e commit --quiet --allow-empty -m "$2"
  git -C "$1" checkout --quiet main
}

gh_repo="$work/github"
mkrepo "$gh_repo" "https://github.com/o/r.git"
branch "$gh_repo" "cp/12-fresh"   "2026-05-25T12:00:00Z"
branch "$gh_repo" "issue-13"      "2025-01-01T12:00:00Z"
branch "$gh_repo" "release-2"     "2026-05-30T12:00:00Z"
branch "$gh_repo" "14-landed"     "2026-04-01T12:00:00Z"

gl_repo="$work/gitlab"
mkrepo "$gl_repo" "https://gitlab.example.com/g/r.git"

# run <repo> <args...> — capture stdout, stderr and status on a fresh call log.
run() {
  local repo="$1"; shift
  : > "$CALL_LOG"
  out=""; err=""; status=0
  out="$(cd "$repo" && bash "$backlog_sh" "$@" 2>"$work/err.txt")" || status=$?
  err="$(cat "$work/err.txt")"
}
issue_line() { grep -E "^ISSUE=[0-9]+ #$1 " <<<"$out" || true; }
field()      { issue_line "$1" | cut -d' ' -f"$2"; }
expect()     { [[ "$2" == "$3" ]] || fail "$1: expected '$3', got '$2'"$'\n'"$out"; }

# --- GitHub ---------------------------------------------------------------------

run "$gh_repo"
expect "github exit" "$status" 0
expect "forge" "$(grep '^FORGE=' <<<"$out")" "FORGE=github"
expect "viewer" "$(grep '^VIEWER=' <<<"$out")" "VIEWER=me"
expect "branch source" "$(grep '^BRANCH_SOURCE=' <<<"$out")" "BRANCH_SOURCE=local"
grep -q -- 'gh issue list --state open --limit 50 .* --assignee @me' "$CALL_LOG" \
  || fail "default scope: expected --assignee @me, calls:"$'\n'"$(cat "$CALL_LOG")"
ok "github: default scope is assigned to me, open"

expect "#10 stage" "$(field 10 3)" review
expect "#10 cr"    "$(field 10 6)" "#20"
expect "#10 flags" "$(field 10 8)" "draft,needs:review"
ok "github: a closing reference puts the issue in review, with the CR's draft flag"

expect "#11 stage" "$(field 11 3)" review
expect "#11 cr"    "$(field 11 6)" "#21"
expect "#11 flags" "$(field 11 8)" "needs:review"
ok "github: a Refs mention on an open CR counts as in flight"

expect "#12 stage"  "$(field 12 3)" branch
expect "#12 branch" "$(field 12 7)" "cp/12-fresh"
ok "github: a fresh branch named for the issue is in flight"

expect "#13 stage" "$(field 13 3)" todo
expect "#13 flags" "$(field 13 8)" old-branch
ok "github: a branch past --stale-days does not promote the issue"

expect "#14 stage" "$(field 14 3)" landed
expect "#14 cr"    "$(field 14 6)" "#22"
expect "#14 branch" "$(field 14 7)" -
ok "github: an open issue a merged PR closed is landed, and the PR's branch is not its own"

expect "#15 stage" "$(field 15 3)" todo
ok "github: a merged PR that only mentioned the issue does not land it"

expect "#16 flags" "$(field 16 8)" "overdue:2026-05-15"
expect "#16 due"   "$(field 16 4)" "2026-05-15"
ok "github: a milestone due date that has passed is overdue"

expect "#17 flags" "$(field 17 8)" "idle:151d"
expect "#18 flags" "$(field 18 8)" "dup:#17"
ok "github: an untouched issue is idle, and a same-titled later one is its duplicate"

expect "#2 stage" "$(field 2 3)" todo
expect "#2 branch" "$(field 2 7)" -
expect "#19 stage" "$(field 19 3)" todo
ok "github: release-2 is not issue 2's branch, and 'prefixes #19' links nothing"

order=$(grep '^ISSUE=' <<<"$out" | cut -d' ' -f2 | tr '\n' ' ')
expect "order" "$order" "#31 #11 #10 #30 #32 #12 #16 #19 #13 #2 #18 #15 #17 #14 "
ok "github: CRs needing review, then ready, then waiting; then branch, todo by due then updated, landed"

expect "#30 flags" "$(field 30 8)" "draft,needs:ready"
expect "#31 flags" "$(field 31 8)" "needs:review"
expect "#32 flags" "$(field 32 8)" -
ok "github: a reviewed draft needs marking ready; a push since the review needs another"

crs=$(grep '^CR=' <<<"$out" | cut -d' ' -f1-6)
expect "cr lines" "$crs" "CR=#27 ready partial review them #31
CR=#20 draft none review me #10
CR=#21 ready none review them #11
CR=#26 draft reviewed ready me #30
CR=#28 ready reviewed wait them #32
CR=#24 ready reviewed wait me -"
ok "github: each CR's draft flag and /anchor:review state, those needing action first; others' untracked CRs omitted"

expect "next" "$(grep '^NEXT=' <<<"$out")" "NEXT=review #27 theirs:partial"
expect "overdue" "$(grep '^OVERDUE=' <<<"$out")" "OVERDUE=#16"
ok "github: the next step is the first CR waiting on the viewer, with overdue unstarted issues named beside it"

# With no CR open, the next step falls to the branch in progress.
NO_CRS=1 run "$gh_repo"
expect "next without CRs" "$(grep '^NEXT=' <<<"$out")" "NEXT=branch #12 cp/12-fresh"
ok "github: with nothing waiting on the viewer, the next step is the branch in progress"

# Scope flags reach gh as gh spells them.
run "$gh_repo" --assignee none --label bug --label "good first" --state all --limit 7
expect "scoped exit" "$status" 0
grep -q -- 'gh issue list --state all --limit 7 .* --search no:assignee --label bug --label good first' "$CALL_LOG" \
  || fail "scope flags, calls:"$'\n'"$(cat "$CALL_LOG")"
expect "scope line" "$(grep '^SCOPE=' <<<"$out")" "SCOPE=assignee:none state:all label:bug label:good first"
ok "github: unassigned, labels, state and limit reach gh"

# A gh that predates closingIssuesReferences still links through the text.
OLD_GH=1 run "$gh_repo"
expect "old gh exit" "$status" 0
expect "old gh #10" "$(field 10 3)" todo
expect "old gh #14" "$(field 14 3)" landed
ok "github: without closingIssuesReferences the description still links"

# A repo with no checkout here takes -R and the forge's branch list.
run "$gl_repo" --forge github --project o/r
expect "project exit" "$status" 0
expect "project branch source" "$(grep '^BRANCH_SOURCE=' <<<"$out")" "BRANCH_SOURCE=forge"
grep -q -- 'gh issue list .* -R o/r' "$CALL_LOG" || fail "--project: no -R on the issue list"
grep -q -- 'gh api repos/o/r/branches' "$CALL_LOG" || fail "--project: branches not read from the forge"
expect "project #12" "$(field 12 7)" "12-remote-only"
expect "project #12 stage" "$(field 12 3)" branch
ok "github: --project reads issues, CRs and branches from the forge"

FAIL_AUTH=1 run "$gh_repo"
expect "auth exit" "$status" 1
grep -q '^BACKLOG_AUTH=1' <<<"$err" || fail "auth: expected BACKLOG_AUTH=1, got: $err"
ok "github: a refused credential is reported as auth, not as an empty backlog"

run "$gh_repo" --state bogus
expect "usage exit" "$status" 64
ok "usage: an unknown --state is a usage error"

# --- GitLab ---------------------------------------------------------------------

run "$gl_repo"
expect "gitlab exit" "$status" 0
expect "gitlab forge" "$(grep '^FORGE=' <<<"$out")" "FORGE=gitlab"
grep -q -- 'glab issue list --output json --per-page 50 --assignee=@me' "$CALL_LOG" \
  || fail "gitlab default scope, calls:"$'\n'"$(cat "$CALL_LOG")"

expect "!5 stage" "$(field 5 3)" review
expect "!5 cr"    "$(field 5 6)" "!7"
expect "!5 flags" "$(field 5 8)" "draft,needs:review"
ok "gitlab: a Closes in the MR description puts the issue in review"

expect "#6 stage" "$(field 6 3)" review
expect "#6 branch" "$(field 6 7)" "6-mr-from-issue"
expect "#6 flags" "$(field 6 8)" -
expect "gitlab !10" "$(grep '^CR=!10 ' <<<"$out" | cut -d' ' -f1-6)" "CR=!10 ready reviewed wait them #6"
ok "gitlab: an MR from the issue's own branch links it"

expect "#8 stage" "$(field 8 3)" landed
expect "#8 due"   "$(field 8 4)" "2026-05-20"
expect "#8 flags" "$(field 8 8)" "overdue:2026-05-20"
ok "gitlab: a merged MR's Fixes lands it, and the milestone's date stands in for a missing due date"

order=$(grep '^ISSUE=' <<<"$out" | cut -d' ' -f2 | tr '\n' ' ')
expect "gitlab order" "$order" "#5 #6 #9 #8 "
ok "gitlab: an MR needing review before one waiting, both before an unstarted issue due sooner"
expect "gitlab next" "$(grep '^NEXT=' <<<"$out")" "NEXT=review !7 own:none"
grep -q '^OVERDUE=' <<<"$out" && fail "gitlab: #8 is landed, not unstarted, so nothing is OVERDUE"
ok "gitlab: the next step is your own unreviewed MR; a landed issue isn't counted overdue"

run "$gl_repo" --assignee none --label a --label b --state closed
grep -q -- 'glab issue list --output json --per-page 50 --closed --label a,b' "$CALL_LOG" \
  || fail "gitlab scope flags, calls:"$'\n'"$(cat "$CALL_LOG")"
expect "gitlab unassigned" "$(grep '^ISSUE_COUNT=' <<<"$out")" "ISSUE_COUNT=1"
expect "gitlab unassigned #6" "$(field 6 2)" "#6"
ok "gitlab: unassigned filters the JSON, labels join with commas, --closed reaches glab"

FAIL_AUTH=1 run "$gl_repo"
expect "gitlab auth exit" "$status" 1
grep -q '^BACKLOG_AUTH=1' <<<"$err" || fail "gitlab auth: expected BACKLOG_AUTH=1, got: $err"
ok "gitlab: a refused credential is reported as auth"

echo "PASS"
