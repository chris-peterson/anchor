#!/usr/bin/env bash
# Survey a backlog for /anchor:backlog: the issues in scope, each crossed against
# the change requests and branches already carrying work for it, ranked, with the
# signs that an issue has fallen out of date.
#
# Why a script (not skill prose): which CR or branch belongs to which issue, what
# is overdue, and what landed without closing its issue are facts, the same on
# every run. Left to the skill, the cross-reference was done on some runs and
# skipped on others, and an issue already in review ranked beside ones nobody had
# started. What the skill keeps is reading the query into scope, presenting the
# list, and judging which out-of-date issue is worth an edit.
#
# Linking. A CR carries work for issue N when its closing references name N
# (GitHub's closingIssuesReferences, or a closes/fixes/resolves/implements
# keyword in its title or description), when it mentions N with refs/part of/
# towards/related to, when its title carries a bare #N, or when its branch name
# does. A branch name carries N as a leading segment (`42-fix-login`,
# `cp/42_fix`) or after issue/issues/gh (`issue-42`, `feature/gh-42`), never as a
# trailing number, which is how `release-2` and `PROJ-42` stay unlinked.
#
# A merged CR links only by a closing reference: a merged CR that merely
# mentioned N was part of the work, not the end of it. An open issue that a
# merged CR closed is `landed` — it most often means the CR merged into a branch
# other than the default, where neither forge closes anything.
#
# Branches come from this checkout's refs (local heads and origin's), and from
# the forge when the target is a repo with no checkout here (--project). A
# branch that is the head of an open or merged CR is that CR's, not a branch of
# its own.
#
# Review state. Each open CR is read for its draft flag and for the rounds
# /anchor:review recorded in its description's Review status section
# (scripts/lib/review-status.sh), so a CR nobody has run /anchor:review on is
# told apart from one waiting on reviewers. A round counts when it covers the
# CR's head commit; one covering only earlier commits is `partial`, which is
# also what a rebase since the review reads as. On someone else's CR only the
# viewer's rounds count, since the question is whether *they* have reviewed it.
#
# Ranking. Work already in flight comes first, since finishing it is cheaper than
# starting something else: stages, in order,
#   review    an open CR carries it
#   branch    a branch carries it, committed to within --stale-days
#   todo      nothing does
#   landed    a merged CR closed it, and it is still open
#   closed    the issue is closed (only when --state includes closed)
# Within `review`, a CR that needs the viewer's action (review, then ready)
# ranks ahead of one that waits on someone else. Within a stage: soonest due
# date first, undated last, then most recently updated. GitHub issues have no
# due date of their own, so the milestone's stands in; on GitLab the issue's own
# due date, else its milestone's.
#
# The next step follows from the same facts, so it is decided here too: a CR
# waiting on the viewer, else a branch in progress, else the top unstarted
# issue.
#
# Output lines (KEY=value, stdout):
#   RESOLVED_VIA=<repo|cwd>, FORGE=<github|gitlab>, VIEWER=<login>
#   SCOPE=assignee:<me|none|any|login> state:<open|closed|all>[ label:<l>]...
#   TODAY=<YYYY-MM-DD>, STALE_DAYS=<n>
#   BRANCH_SOURCE=<local|forge|none>   none: the forge's branch list failed
#   ISSUE_COUNT=<n>
#   ISSUE=<rank> <#n> <stage> <due|-> <updated> <cr|-> <branch|-> <flags|-> <url> <title>
#       cr      the most recently updated open CR (#n on GitHub, !n on GitLab),
#               or for `landed` the merged CR that closed it
#       flags   comma-separated, or -:
#               draft            the open CR is a draft
#               needs:<step>     the open CR needs the viewer to act (CR= next)
#               crs:<n>          more than one open CR carries it
#               overdue:<date>   the due date has passed
#               idle:<days>d     todo, and untouched for more than --stale-days
#               old-branch       its branch's last commit is past --stale-days
#               dup:#<n>         an issue in the list with a lower number has
#                                the same title
#   CR=<cr> <draft|ready> <review> <next> <author> <issues|-> <branch> <url> <title>
#       each open CR tied to an issue in the list, and each of the viewer's own
#       open CRs (issues `-`: it names none), those needing action first
#       review  reviewed|partial|none   /anchor:review rounds, as above
#       next    review   the viewer's own CR with its head unreviewed, or
#                        someone else's ready CR the viewer hasn't reviewed
#               ready    the viewer's own draft, reviewed: mark it ready
#               wait     on reviewers, on the author (someone else's draft),
#                        or on merge
#   NEXT=<step> <ref> <detail>
#       review <cr> <own|theirs>:<none|partial>   run /anchor:review on it
#       ready  <cr> own                           run /anchor:ready on it
#       branch <#n> <branch>                      pick the branch back up
#       issue  <#n> -                             start the top unstarted issue
#       none   - -                                nothing open in scope
#   OVERDUE=<#n>[,<#n>...]   unstarted issues past their due date; absent when
#                            there are none
#   DETAILS=<path>           the descriptions of the top --details ranked
#                            issues (default 20), in rank order, as one markdown
#                            section per issue (`## #<n> <title>`, its URL, then
#                            the body, capped at 1500 characters), so the skill
#                            can summarize what each asks without a view call
#                            per issue; absent when no issue is listed
#   DETAILS_COUNT=<n>        how many issues DETAILS holds
#
# Errors: BACKLOG_ERROR=<message> on stderr, plus BACKLOG_AUTH=1 when the forge
# refused the credentials.
#
# Exit codes: 0 done · 1 BACKLOG_ERROR · 64 usage error
#
# Usage:
#   backlog.sh                                   # assigned to me, open
#   backlog.sh --assignee any --label bug
#   backlog.sh --assignee none --state all --limit 100
#   backlog.sh --details 50                      # summarize more of a long list
#   backlog.sh --project owner/repo              # a repo with no checkout here
#   backlog.sh --repo /path/to/checkout

set -euo pipefail

# shellcheck source=lib/resolve-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-context.sh"
# shellcheck source=lib/forge-url.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge-url.sh"
# shellcheck source=lib/tmpfile.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tmpfile.sh"

CTX_REPO=""
forge=""
project=""
assignee=me
state=open
limit=50
stale_days=60
details_max=20
labels=()

usage() { echo "BACKLOG_ERROR=$*" >&2; exit 64; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge)      forge="${2:-}"; shift 2 ;;
    --project)    [[ -n "${2:-}" ]] || usage "--project needs a repo"; project="$2"; shift 2 ;;
    --repo)       [[ -n "${2:-}" ]] || usage "--repo needs a path"; CTX_REPO="$2"; shift 2 ;;
    --assignee)   [[ -n "${2:-}" ]] || usage "--assignee needs a value"; assignee="$2"; shift 2 ;;
    --label)      [[ -n "${2:-}" ]] || usage "--label needs a value"; labels+=("$2"); shift 2 ;;
    --state)      state="${2:-}"; shift 2 ;;
    --limit)      limit="${2:-}"; shift 2 ;;
    --stale-days) stale_days="${2:-}"; shift 2 ;;
    --details)    details_max="${2:-}"; shift 2 ;;
    *) usage "unrecognized argument: $1" ;;
  esac
done

case "$state" in open|closed|all) ;; *) usage "--state must be open, closed, or all, got: $state" ;; esac
case "$forge" in github|gitlab|"") ;; *) usage "--forge must be github or gitlab, got: $forge" ;; esac
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || usage "--limit must be a positive integer, got: $limit"
[[ "$stale_days" =~ ^[1-9][0-9]*$ ]] || usage "--stale-days must be a positive integer, got: $stale_days"
[[ "$details_max" =~ ^[0-9]+$ ]] || usage "--details must be a non-negative integer, got: $details_max"

ctx_resolve_repo

if [[ -z "$forge" ]]; then
  case "$project" in
    *github.com*) forge=github ;;
    *gitlab*)     forge=gitlab ;;
    *)            forge=$(anchor_forge_of_origin) ;;
  esac
  [[ "$forge" != none ]] || usage "origin is neither GitHub nor GitLab; pass --forge"
fi

fail() {
  local out="$1"
  echo "BACKLOG_ERROR=$out" | head -n 3 >&2
  if grep -qiE '401|403|unauthori[sz]ed|authentication|not logged|auth login' <<<"$out"; then
    echo "BACKLOG_AUTH=1" >&2
  fi
  exit 1
}

# forge <cmd...> — run a CLI call, failing the run with its output.
forge_read() {
  local out
  out=$("$@" 2>&1) || fail "$out"
  printf '%s\n' "$out"
}

today="${ANCHOR_TODAY:-$(date -u +%Y-%m-%d)}"

viewer=$(anchor_forge_self "$forge") || fail "$viewer"

repo_flag=()
[[ -z "$project" ]] || repo_flag=(-R "$project")

if [[ "$forge" == github ]]; then
  args=(issue list --state "$state" --limit "$limit"
        --json "number,title,url,state,updatedAt,milestone,assignees,body")
  case "$assignee" in
    me)   args+=(--assignee "@me") ;;
    none) args+=(--search "no:assignee") ;;
    any)  ;;
    *)    args+=(--assignee "$assignee") ;;
  esac
  for l in "${labels[@]+"${labels[@]}"}"; do args+=(--label "$l"); done
  issues=$(forge_read gh "${args[@]}" "${repo_flag[@]+"${repo_flag[@]}"}")

  cr_fields=number,title,url,body,headRefName,headRefOid,isDraft,author,updatedAt
  # closingIssuesReferences arrived later than the rest; an older gh that
  # doesn't know it still links through the description and branch.
  if open_crs=$(gh pr list --state open --limit 100 --json "$cr_fields,closingIssuesReferences" \
                  "${repo_flag[@]+"${repo_flag[@]}"}" 2>&1); then
    merged_crs=$(forge_read gh pr list --state merged --limit 50 --json "$cr_fields,closingIssuesReferences" \
                   "${repo_flag[@]+"${repo_flag[@]}"}")
  elif grep -q 'closingIssuesReferences' <<<"$open_crs"; then
    open_crs=$(forge_read gh pr list --state open --limit 100 --json "$cr_fields" "${repo_flag[@]+"${repo_flag[@]}"}")
    merged_crs=$(forge_read gh pr list --state merged --limit 50 --json "$cr_fields" "${repo_flag[@]+"${repo_flag[@]}"}")
  else
    fail "$open_crs"
  fi
else
  args=(issue list --output json --per-page "$limit")
  case "$state" in closed) args+=(--closed) ;; all) args+=(--all) ;; esac
  case "$assignee" in
    me)       args+=(--assignee=@me) ;;
    none|any) ;;
    *)        args+=(--assignee="$assignee") ;;
  esac
  if [[ ${#labels[@]} -gt 0 ]]; then
    joined=$(IFS=,; printf '%s' "${labels[*]}")
    args+=(--label "$joined")
  fi
  issues=$(forge_read glab "${args[@]}" "${repo_flag[@]+"${repo_flag[@]}"}")
  # glab has no "no assignee" filter (forge cookbook, "Issue list").
  if [[ "$assignee" == none ]]; then
    issues=$(jq '[.[] | select((.assignees // []) | length == 0)]' <<<"$issues")
  fi
  open_crs=$(forge_read glab mr list --output json --per-page 100 "${repo_flag[@]+"${repo_flag[@]}"}")
  merged_crs=$(forge_read glab mr list --merged --output json --per-page 50 "${repo_flag[@]+"${repo_flag[@]}"}")
fi

# Branches, as [{name, ts}] with ts in epoch seconds (0 when the forge's list
# carries no date, which counts as active rather than old).
branch_source=local
if [[ -z "$project" ]]; then
  default=$(anchor_default_branch || true)
  branches=$(git for-each-ref --format='%(refname)%09%(committerdate:unix)' refs/heads refs/remotes/origin \
    | jq -R -s --arg default "$default" '
        split("\n") | map(select(length > 0) | split("\t")
          | {name: (.[0] | sub("^refs/heads/"; "") | sub("^refs/remotes/origin/"; "")),
             ts: (.[1] | tonumber? // 0)})
        | map(select(.name != "HEAD" and .name != $default))
        | group_by(.name) | map(max_by(.ts))')
elif [[ "$forge" == github ]]; then
  slug="${project#*://}"; slug="${slug#github.com/}"; slug="${slug%.git}"
  if out=$(gh api "repos/$slug/branches?per_page=100" 2>&1); then
    branches=$(jq '[.[] | {name, ts: 0}]' <<<"$out")
    branch_source=forge
  else
    branches='[]'; branch_source=none
  fi
else
  host_path="${project#*://}"; host_path="${host_path%.git}"
  path="${host_path#*/}"
  if out=$(glab api --hostname "${host_path%%/*}" \
             "projects/${path//\//%2F}/repository/branches?per_page=100" 2>&1); then
    branches=$(jq '[.[] | {name, ts: ((.commit.committed_date // "")[0:19] + "Z" | fromdateiso8601? // 0)}]' <<<"$out")
    branch_source=forge
  else
    branches='[]'; branch_source=none
  fi
fi

scope="assignee:$assignee state:$state"
for l in "${labels[@]+"${labels[@]}"}"; do scope+=" label:$l"; done

echo "RESOLVED_VIA=$RESOLVED_VIA"
echo "FORGE=$forge"
echo "VIEWER=$viewer"
echo "SCOPE=$scope"
echo "TODAY=$today"
echo "STALE_DAYS=$stale_days"
echo "BRANCH_SOURCE=$branch_source"

# shellcheck disable=SC2016 # a jq program, not shell
program='
def ts: if . == null or . == "" then 0 else (.[0:19] + "Z" | fromdateiso8601? // 0) end;
def now_ts: $today + "T00:00:00Z" | fromdateiso8601;

# Issue numbers a branch name carries: a leading segment, or after issue/gh.
def branch_nums:
  ascii_downcase
  | [ (split("/")[] | match("^([0-9]+)(?:[-_.]|$)") | .captures[0].string),
      (match("(?:^|[/_-])(?:issues?|gh)[-_]?#?([0-9]+)(?:[/_.-]|$)"; "g") | .captures[0].string) ]
  | map(tonumber) | unique;

def closing_nums:
  [ match("\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|implement(?:s|ed)?)[:\\s]+(?:\\S*/issues/|#)([0-9]+)"; "gi")
    | .captures[0].string | tonumber ] | unique;
def mention_nums:
  [ match("\\b(?:refs?|part of|towards?|related to)[:\\s]+(?:\\S*/issues/|#)([0-9]+)"; "gi")
    | .captures[0].string | tonumber ] | unique;

def norm_issue:
  if $forge == "github" then
    {n: .number, title, url, state: (.state | ascii_downcase),
     due: (.milestone.dueOn // null | if . then .[0:10] else null end), updated: .updatedAt}
  else
    {n: .iid, title, url: .web_url, state: (if .state == "opened" then "open" else .state end),
     due: (.due_date // .milestone.due_date // null), updated: .updated_at}
  end;

# The rounds /anchor:review recorded in a description (scripts/lib/review-status.sh):
# {"<sha>": {rounds, by, ...}}, or {} without the section.
def review_data:
  ([match("<!-- anchor:review-status([\\s\\S]*?)-->") | .captures[0].string | fromjson?] | .[0]) // {};

# reviewed: a round covers the head commit; partial: rounds cover earlier
# commits only; none: no round. On someone else'"'"'s CR only the viewer'"'"'s rounds count.
def review_state:
  (.author == $viewer) as $own | .head as $head
  | [ .rounds | to_entries[]
      | select((.value.rounds // 0) > 0 and ($own or ((.value.by // []) | index($viewer))))
      | .key ] as $keys
  | if ($keys | length) == 0 then "none"
    elif $head != "" and any($keys[]; . as $k | ($head | startswith($k)) or ($k | startswith($head))) then "reviewed"
    else "partial" end;

# What the CR is waiting on, from where the viewer sits.
def next_step:
  if .author == $viewer then
    (if .review != "reviewed" then "review" elif .draft then "ready" else "wait" end)
  else
    (if .draft then "wait" elif .review != "reviewed" then "review" else "wait" end)
  end;
def next_rank: {review: 0, ready: 1}[.] // 2;

def norm_cr:
  if $forge == "github" then
    {n: .number, ref: ("#" + (.number | tostring)), url, title, body: (.body // ""),
     branch: .headRefName, head: (.headRefOid // ""), draft: (.isDraft // false), author: (.author.login // ""),
     updated: .updatedAt, closes: [(.closingIssuesReferences // [])[] | .number]}
  else
    {n: .iid, ref: ("!" + (.iid | tostring)), url: .web_url, title, body: (.description // ""),
     branch: .source_branch, head: (.sha // ""), draft: (.draft // .work_in_progress // false),
     author: (.author.username // ""), updated: .updated_at, closes: []}
  end
  | ((.title // "") + "\n" + .body) as $text
  | .closes = ((.closes + ($text | closing_nums)) | unique)
  | .links = ((.closes + ($text | mention_nums) + (.branch | branch_nums)
               + [(.title // "") | match("#([0-9]+)"; "g") | .captures[0].string | tonumber]) | unique)
  | .rounds = (.body | review_data)
  | .review = review_state
  | .next = next_step;

($open | map(norm_cr)) as $open
| ($merged | map(norm_cr)) as $merged
| ([$open[].branch, $merged[].branch]) as $cr_branches
| ($branches | map(select(.name as $b | $cr_branches | index($b) | not))) as $branches
| (now_ts) as $now
| ($stale * 86400) as $stale_s
| ($issues | map(norm_issue)) as $all
| [ $all[]
    | . as $i
    | ([$open[] | select(.links | index($i.n))] | sort_by(.updated) | reverse | sort_by(.next | next_rank)) as $crs
    | ([$merged[] | select(.closes | index($i.n))] | sort_by(.updated) | reverse) as $landed
    | ([$branches[] | select(.name | branch_nums | index($i.n))] | sort_by(.ts) | reverse) as $brs
    | ($brs[0] // null) as $br
    | ($br != null and ($br.ts == 0 or ($now - $br.ts) <= $stale_s)) as $br_active
    | (if $i.state != "open" then "closed"
       elif ($crs | length) > 0 then "review"
       elif $br_active then "branch"
       elif ($landed | length) > 0 then "landed"
       else "todo" end) as $stage
    | (($now - ($i.updated | ts)) / 86400 | floor) as $age
    | $i + {
        stage: $stage,
        cr: (if $stage == "landed" then $landed[0].ref elif ($crs | length) > 0 then $crs[0].ref else null end),
        next: (if ($crs | length) > 0 then $crs[0].next else null end),
        branch: (if ($crs | length) > 0 then $crs[0].branch elif $br then $br.name else null end),
        flags: ([
          (if ($crs | length) > 0 and $crs[0].draft then "draft" else empty end),
          (if ($crs | length) > 0 and $crs[0].next != "wait" then "needs:\($crs[0].next)" else empty end),
          (if ($crs | length) > 1 then "crs:\($crs | length)" else empty end),
          (if $i.state == "open" and $i.due != null and $i.due < $today then "overdue:\($i.due)" else empty end),
          (if $stage == "todo" and $age > $stale then "idle:\($age)d" else empty end),
          (if $br != null and ($br_active | not) and ($crs | length) == 0 then "old-branch" else empty end),
          ([$all[] | select(.n < $i.n and (.title | ascii_downcase) == ($i.title | ascii_downcase)) | .n] | min
            | if . then "dup:#\(.)" else empty end)
        ])
      } ]
| sort_by(.updated) | reverse | sort_by(.due // "9999-12-31")
| sort_by([{review: 0, branch: 1, todo: 2, landed: 3, closed: 4}[.stage], (.next // "" | next_rank)]) as $ranked
| "ISSUE_COUNT=\($ranked | length)",
  ($ranked | to_entries[] | .key as $k | .value
    | "ISSUE=\($k + 1) #\(.n) \(.stage) \(.due // "-") \(.updated[0:10]) \(.cr // "-") \(.branch // "-") \(if (.flags | length) > 0 then .flags | join(",") else "-" end) \(.url) \(.title | gsub("[\r\n]+"; " "))"),
  (([$all[].n]) as $nums
   | ($open | map(. + {issues: [.links[] | select(. as $n | $nums | index($n))]})
      | map(select(.author == $viewer or (.issues | length) > 0))
      | sort_by(.updated) | reverse | sort_by(.next | next_rank)) as $crs
   | ($crs[]
      | "CR=\(.ref) \(if .draft then "draft" else "ready" end) \(.review) \(.next) \(.author) \(if (.issues | length) > 0 then .issues | map("#\(.)") | join(",") else "-" end) \(.branch) \(.url) \(.title | gsub("[\r\n]+"; " "))"),
     ( [$crs[] | select(.next != "wait")
         | "NEXT=\(.next) \(.ref) \(if .next == "ready" then "own" else "\(if .author == $viewer then "own" else "theirs" end):\(.review)" end)"]
       + [$ranked[] | select(.stage == "branch") | "NEXT=branch #\(.n) \(.branch)"]
       + [$ranked[] | select(.stage == "todo") | "NEXT=issue #\(.n) -"]
       + ["NEXT=none - -"] | .[0]),
     ([$ranked[] | select(.stage == "todo" and any(.flags[]; startswith("overdue:"))) | "#\(.n)"]
       | select(length > 0) | "OVERDUE=\(join(","))"))
'

if ! report=$(jq -n -r \
     --arg forge "$forge" --arg today "$today" --arg viewer "$viewer" \
     --argjson stale "$stale_days" \
     --argjson issues "$issues" --argjson open "$open_crs" --argjson merged "$merged_crs" \
     --argjson branches "$branches" "$program"); then
  fail "could not read the forge's JSON"
fi
printf '%s\n' "$report"

# Details. The issue list already carried each description, so the skill gets
# them here rather than viewing each issue on its own: a summary of what an
# issue asks is what makes the table worth reading, and one view call per issue
# is a prompt per issue. A literal /tmp, since the agent reads the file.
#
# Bounded twice, because the agent reads the whole file into its context: the
# top --details issues only, since a summary matters most for the issues near
# the top and a long list reads poorly as a table anyway, and 1500 characters
# of each, which holds the problem statement a summary is drawn from.
order=$({ grep '^ISSUE=' <<<"$report" || true; } | cut -d' ' -f2 | tr -d '#' \
          | jq -R -s -c --argjson max "$details_max" \
              'split("\n") | map(select(length > 0) | tonumber) | .[0:$max]')
if [[ "$order" != "[]" ]]; then
  details="$(anchor_edit_tmpdir anchor-backlog)/issues.md"
  # shellcheck disable=SC2016 # a jq program, not shell
  jq -n -r --arg forge "$forge" --argjson issues "$issues" --argjson order "$order" '
    ($issues | map(if $forge == "github"
                   then {n: .number, title, url, body: (.body // "")}
                   else {n: .iid, title, url: .web_url, body: (.description // "")} end)) as $all
    | $order[] as $n | $all[] | select(.n == $n)
    | "## #\(.n) \(.title | gsub("[\r\n]+"; " "))\n\n\(.url)\n\n"
      + (if (.body | gsub("\\s"; "")) == "" then "_No description._"
         elif (.body | length) > 1500 then .body[0:1500] + "\n\n_Truncated; the full description is at the URL above._"
         else .body end)
      + "\n"' > "$details" || fail "could not write the issue details"
  echo "DETAILS=$details"
  echo "DETAILS_COUNT=$(jq length <<<"$order")"
fi
