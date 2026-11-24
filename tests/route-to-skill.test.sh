#!/usr/bin/env bash
# Functional test for hooks/route-to-skill.sh, the PreToolUse guard on Bash.
#
# Feeds the hook the JSON Claude Code sends and asserts the decision: a raw
# release publish is denied with a reason that names /anchor:release, a raw CR
# create or description write one that names /anchor:prepare-review, each
# opening with its rule's marker; everything else — the skills' own scripts,
# read-only calls, a workflow that isn't a release, a CR edit no skill owns, a
# command that only mentions one — passes with nothing printed. A false deny costs a session its next step and
# names a skill that can't do the job, so the passes are as load-bearing as the
# denies.
#
# The commands below are literal text for the hook to read, never expanded here.
# shellcheck disable=SC2016
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/../hooks/route-to-skill.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "# jq is not on PATH; skipping"
  echo "PASS"
  exit 0
fi

run() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook"
}

# denies <rule> <command>: a deny whose reason opens with the rule's marker and
# names its skill and the script that skill writes through.
denies() {
  local rule="$1" cmd="$2" skill script out reason
  case "$rule" in
    route-release) skill=/anchor:release;        script=scripts/release-publish.sh ;;
    route-cr)      skill=/anchor:prepare-review; script=scripts/prepare-review.sh ;;
    *) fail "unknown rule: $rule" ;;
  esac
  out=$(run "$cmd")
  [[ -n "$out" ]] || fail "expected a deny for: $cmd"
  [[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" == deny ]] \
    || fail "not a deny for: $cmd -> $out"
  reason=$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")
  [[ "$reason" == "[anchor:$rule]"* ]] || fail "reason lacks the marker: $reason"
  [[ "$reason" == *"$skill"* ]] || fail "reason doesn't name the skill: $reason"
  [[ "$reason" == *"$script"* ]] || fail "reason doesn't name the allowed route: $reason"
  ok "denies ($rule): $cmd"
}

passes() {
  local out
  out=$(run "$1")
  [[ -z "$out" ]] || fail "expected no output for: $1 -> $out"
  ok "passes: $1"
}

# --- denied: the commands a session reached for -------------------------------
denies route-release 'gh workflow run .github/workflows/release.yml -f bump=minor'
denies route-release 'gh workflow run release.yml -R acme/widget --ref main -f bump=minor'
denies route-release 'cd /src/acme-widget; gh workflow run release.yml -f bump=patch'
denies route-release 'cd /src/acme-widget && gh workflow run publish.yml -f level=major'
denies route-release "gh workflow run publish.yml -f level='minor'"
denies route-release 'for r in foo bar; do gh workflow run release.yml -R acme/$r -f bump=minor && echo "$r"; done'
denies route-release 'gh release create v1.2.3 --notes-file /tmp/notes.md'
denies route-release 'gh release create v1.2.3 --generate-notes'
denies route-release 'glab release create v1.2.3 --notes-file /tmp/notes.md'
denies route-release 'GH_HOST=github.com gh release create v1.2.3 -F notes.md'
denies route-release 'out=$(gh release create v1.2.3 --notes-file n.md)'
denies route-release 'gh api repos/acme/widget/releases -f tag_name=v1.2.3'
denies route-release 'gh api -X POST repos/acme/widget/actions/workflows/release.yml/dispatches -f ref=main'
denies route-release 'glab api --method POST projects/acme%2Fwidget/releases -f tag_name=v1.2.3'
denies route-release $'git push origin main\ngh workflow run release.yml -f bump=minor'

# A `\`-continued call is one command: its fields are on the next line.
denies route-release $'gh api -X POST \\\n  repos/acme/widget/releases \\\n  -f tag_name=v1.2.3'

# --- denied: a raw CR create or description write -----------------------------
denies route-cr 'gh pr create --draft --title "Fix it" --body-file /tmp/cr.md'
denies route-cr 'gh pr create --fill'
denies route-cr 'glab mr create --draft --title "Fix it" --description "body"'
denies route-cr 'git push -u origin topic && gh pr create --fill'
denies route-cr 'gh pr edit 58 --body-file /tmp/cr-body.md'
denies route-cr 'gh pr edit 58 -F /tmp/cr-body.md'
denies route-cr 'gh pr edit 58 --body "new text"'
denies route-cr 'gh pr edit 58 -b "new text" --add-label docs'
denies route-cr 'gh pr edit https://github.com/acme/widget/pull/58 --title "New" --body-file=/tmp/b.md'
denies route-cr 'glab mr update 12 --description "new text"'
denies route-cr 'glab mr update 12 -d "new text"'
denies route-cr 'glab mr update 12 --description-file /tmp/b.md'
denies route-cr 'glab mr update 12 --attach shot.png'
denies route-cr 'glab mr update 12 --fill --yes'
denies route-cr 'gh api repos/acme/widget/pulls -f title=Fix -f head=topic -f base=main -f body=x'
denies route-cr 'gh api -X PATCH repos/acme/widget/pulls/58 -F body=@/tmp/b.md'
denies route-cr 'gh api --method PATCH repos/{owner}/{repo}/pulls/58 --field body=x'
denies route-cr 'glab api -X POST projects/:fullpath/merge_requests -f source_branch=topic -f target_branch=main -f title=Fix'
denies route-cr 'glab api -X PUT projects/:fullpath/merge_requests/12 -F "description=@/tmp/b.md"'
denies route-cr $'glab api -X PUT projects/:fullpath/merge_requests/12 \\\n  -F "description=@/tmp/b.md"'
denies route-cr 'gh api graphql -f query="mutation { createPullRequest(input: {repositoryId: \"R\", baseRefName: \"main\", headRefName: \"t\", title: \"x\"}) { pullRequest { url } } }"'
denies route-cr 'gh api graphql -f query="mutation { updatePullRequest(input: {pullRequestId: \"P\", body: \"x\"}) { pullRequest { url } } }"'

# beacon#58: a description rewritten for edits that were never committed. The
# hook doesn't read the tree, so the deny holds in a dirty checkout too, and
# prepare-review's own STATE=dirty stop is what the session reaches instead.
dirty=$(mktemp -d)
git -C "$dirty" init -q
echo change > "$dirty/f.txt"
out=$(cd "$dirty" && jq -n --arg c 'gh pr edit 58 --body-file /tmp/cr-body.md' \
  '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$hook")
rm -rf "$dirty"
[[ "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" == "[anchor:route-cr]"* ]] \
  || fail "description write in a dirty tree not denied: $out"
ok "denies (route-cr): a description write from a dirty working tree"

# --- passed: the skill's route, reads, and the unrelated ----------------------
passes 'bash "/plugins/anchor/scripts/release-publish.sh" --dispatch .github/workflows/release.yml --input bump=minor'
passes 'bash "/plugins/anchor/scripts/release-publish.sh" --release v1.2.3 --notes-file /tmp/notes.md'
passes 'bash "/plugins/anchor/scripts/release-recon.sh"'
passes 'gh release view --json url,tagName'
passes 'glab release view -F json'
passes 'gh release list --limit 5'
passes 'gh run list --workflow release.yml --limit 1 --json databaseId,status,url'
passes 'gh workflow view release.yml --yaml'
passes 'gh workflow run deploy-docs.yml --ref main'
passes 'gh workflow run lint.yml -f target=docs'
passes 'gh api repos/acme/widget/releases/latest'
passes 'gh api repos/acme/widget/releases --jq ".[0].tag_name"'
passes 'gh api -X GET repos/acme/widget/releases -f per_page=5'
passes 'bash "/plugins/anchor/scripts/prepare-review.sh" --open --onto main --title "Fix it" --body-file /tmp/cr.md'
passes 'bash "/plugins/anchor/scripts/prepare-review.sh" --write --body-file /tmp/cr.md --cr 58'
passes 'bash "/plugins/anchor/scripts/stack.sh" move --onto main'
passes 'gh pr view 58 --json body,title'
passes 'gh pr list --state open'
passes 'gh pr diff 58'
passes 'gh pr checks 58'
passes 'glab mr view 12 --output json'
passes 'gh pr edit 58 --add-label docs --milestone "v2.2"'
passes 'gh pr edit 58 --title "A better title"'
passes 'gh pr edit 58 --base main'
passes 'gh pr edit 58 --add-reviewer monalisa'
passes 'glab mr update 12 --label a,b --milestone v2.2'
passes 'glab mr update 12 --ready'
passes 'glab mr update 12 --draft'
passes 'glab mr update 12 --title "A better title"'
passes 'glab mr update 12 --target-branch main'
passes 'gh api repos/acme/widget/pulls'
passes 'gh api repos/acme/widget/pulls/58 --jq .body'
passes 'gh api -X GET repos/acme/widget/pulls -f state=open'
passes 'gh api -X PATCH repos/acme/widget/pulls/58 -f title=Better'
passes 'gh api -X POST repos/acme/widget/pulls/58/comments -f body=nit'
passes 'gh api -X POST repos/acme/widget/pulls/58/reviews --input /tmp/review.json'
passes 'gh api -X POST repos/acme/widget/pulls/58/requested_reviewers -f "reviewers[]=monalisa"'
passes 'glab api "projects/:fullpath/merge_requests?state=opened"'
passes 'glab api projects/:fullpath/merge_requests/12'
passes $'glab api -X PUT projects/:fullpath/merge_requests/12 \\\n  -F remove_source_branch=true'
passes 'glab api -X POST "projects/:fullpath/merge_requests/12/blocks" -F blocking_merge_request_iid=11'
passes 'glab api -X POST projects/:fullpath/merge_requests/12/notes -f body=hi'
passes 'glab api -X POST projects/:fullpath/merge_requests/12/discussions -F body=@/tmp/n.md'
passes 'glab api --method POST projects/42/uploads --form "file=@shot.png"'
passes 'gh api graphql -f query="{ repository(owner: \"a\", name: \"b\") { pullRequest(number: 1) { body } } }"'
passes 'gh api graphql -f query="mutation { updatePullRequest(input: {pullRequestId: \"P\", title: \"x\"}) { pullRequest { url } } }"'
passes 'gh pr ready 58'
passes 'grep -rn "gh pr create" guides/'
passes 'echo "run gh pr edit 58 --body-file x to fix it"'
passes 'grep -n "gh release create" guides/forge-cookbook.md'

# A quoted heredoc's body is text, never run: prose that names a command passes.
passes $'cat > notes.md <<\'EOF\'\nOpen it with `gh pr create`, never by hand.\nEOF'
passes $'python3 - <<\'PY\'\nrep("`gh workflow run` on a release workflow")\nPY'
passes $'git commit -F - <<"MSG"\nStop a raw `gh pr edit --body` from landing.\nMSG'
passes $'cat <<\\EOF\n$(gh release create v1)\nEOF'
passes $'cat <<-\'EOF\'\n\t`glab mr update 12 --description x`\n\tEOF'
# ...but what follows the heredoc still runs, and an unquoted one expands.
denies route-cr $'cat > notes.md <<\'EOF\'\ntext\nEOF\ngh pr create --fill'
denies route-cr $'cat <<EOF\n`gh pr create --fill`\nEOF'
passes 'rg "gh workflow run release.yml -f bump=minor" skills/'
passes 'git tag -a v1.2.3 -F notes.md'
passes 'ls -la'
passes ''

# Input it can't read fails open.
out=$(printf 'not json at all: release' | bash "$hook") || fail "hook exited non-zero on bad input"
[[ -z "$out" ]] || fail "bad input produced output: $out"
ok "fails open on unreadable input"

# Without jq the hook reads the command out of the JSON itself, and must reach
# the same decisions: escaped quotes, a continued line, and a second command on
# its own line all come back as the shell would see them.
nojq=$(mktemp -d)
for t in bash cat; do ln -s "$(command -v "$t")" "$nojq/$t"; done
run_nojq() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' > "$nojq/in.json"
  PATH="$nojq" bash "$hook" < "$nojq/in.json"
}
for c in 'gh pr edit 58 --body-file /tmp/cr-body.md' \
         $'glab api -X PUT projects/:fullpath/merge_requests/12 \\\n  -F "description=@/tmp/b.md"' \
         $'git status\ngh pr create --title "Fix it" --fill'; do
  out=$(run_nojq "$c")
  [[ "$out" == *'"permissionDecision":"deny"'*'[anchor:route-cr]'* ]] || fail "no-jq: expected a deny for: $c -> $out"
  ok "denies without jq: $c"
done
out=$(run_nojq 'gh workflow run release.yml -f bump=minor')
[[ "$out" == *'[anchor:route-release]'* ]] || fail "no-jq: release dispatch not denied: $out"
ok "denies without jq: a release dispatch"
for c in 'gh pr edit 58 --add-label docs' 'echo "gh pr create"' 'gh pr view 58' \
         $'cat > notes.md <<\'EOF\'\nOpen it with `gh pr create`, never by hand.\nEOF'; do
  out=$(run_nojq "$c")
  [[ -z "$out" ]] || fail "no-jq: expected no output for: $c -> $out"
  ok "passes without jq: $c"
done
rm -r "$nojq"

echo "PASS"
