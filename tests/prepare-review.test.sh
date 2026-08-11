#!/usr/bin/env bash
# Functional test for scripts/prepare-review.sh's DELETE_BRANCH_ON_MERGE and
# TEMPLATE_* keys.
#
# The template half covers the resolution order — project setting, repo-local
# files, the forge's inherited templates, then anchor.crTemplateRepo — and the
# deterministic pick within a level. Both are places where "whatever came back
# first" was the old behavior, and neither forge answers the same way: GitLab
# resolves the whole hierarchy through one templates endpoint, while GitHub has
# only the owner's `.github` repo behind the six repo-local paths.
#
# The key exists because the two forges carry the preference in different places:
# GitLab takes `remove_source_branch` per MR (so the create call sets it), while
# GitHub has no per-PR field at all — only the repo-wide `deleteBranchOnMerge`.
# A GitHub PR anchor opens therefore carries no preference, and the branch
# survives any merge that doesn't pass `--delete-branch`. The script reports the
# fact so the skill can name it instead of the user discovering the leftover
# branch after the merge.
#
# Drives the real script against a local bare remote and stub `gh` / `glab`
# binaries. The remote path embeds `github.com` / `gitlab.com` as a directory
# component because forge detection matches on the origin URL, and a rewrite via
# `url.<x>.insteadOf` doesn't work — `git remote get-url` reports the rewritten
# path, which would read as no forge at all.
set -euo pipefail

# Hermetic: ignore the user's global/system git config (hooks, templates, a
# global anchor.* key) so the test's behavior doesn't depend on the environment.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare_review_sh="$here/../scripts/prepare-review.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/anchor-prepare-review-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

bin="$work/bin"
mkdir -p "$bin"

# --- stub gh: serves $CR_JSON (empty file == no PR open), installs
# --- $CR_AFTER_CREATE on `pr create`, and reports the repo-wide branch-deletion
# --- setting from $DELETE_ON_MERGE (`true` / `false` / `error` to fail the read).
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CALL_LOG"
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)   [[ -s "$CR_JSON" ]] || exit 1; cat "$CR_JSON" ;;
      create) cp "$CR_AFTER_CREATE" "$CR_JSON"
              echo "https://github.com/example/repo/pull/7" ;;
      *) echo "stub gh: unhandled pr subcommand: ${2:-}" >&2; exit 1 ;;
    esac ;;
  repo)
    case "${2:-}" in
      view) if [[ "$*" == *owner* ]]; then echo "$GH_OWNER"; exit 0; fi
            [[ "$DELETE_ON_MERGE" == error ]] && { echo "stub gh: repo view failed" >&2; exit 1; }
            printf '{"deleteBranchOnMerge":%s}\n' "$DELETE_ON_MERGE" ;;
      *) echo "stub gh: unhandled repo subcommand: ${2:-}" >&2; exit 1 ;;
    esac ;;
  # Contents API backed by $GH_REMOTE/<owner>/<repo>/<path>: a missing repo dir
  # is the 404 that ends the inherited lookup, and a directory path lists its
  # files the way `--jq '.[] | .name'` would.
  api)
    path="${2#repos/}"
    repo="${path%%/contents/*}"
    [[ -d "$GH_REMOTE/$repo" ]] || { echo "stub gh: 404 $repo" >&2; exit 1; }
    [[ "$path" == "$repo" ]] && { echo '{"full_name":"'"$repo"'"}'; exit 0; }
    target="$GH_REMOTE/$repo/${path#*/contents/}"
    if [[ -d "$target" ]]; then
      find "$target" -maxdepth 1 -type f -exec basename {} \; | sort
    elif [[ -f "$target" ]]; then
      cat "$target"
    else
      echo "stub gh: 404 $target" >&2; exit 1
    fi ;;
  *) echo "stub gh: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

# --- stub glab: same contract on the MR side; `api user` serves the username the
# --- create call assigns to.
cat > "$bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'glab %s\n' "$*" >> "$CALL_LOG"
case "${1:-}" in
  mr)
    case "${2:-}" in
      view)   [[ -s "$CR_JSON" ]] || exit 1; cat "$CR_JSON" ;;
      create) cp "$CR_AFTER_CREATE" "$CR_JSON"
              echo "https://gitlab.com/example/repo/-/merge_requests/7" ;;
      *) echo "stub glab: unhandled mr subcommand: ${2:-}" >&2; exit 1 ;;
    esac ;;
  # Templates come from $GL_TPL_DIR/<project>/, one .md per template — the
  # listing endpoint derives from the directory and the named endpoint returns
  # its body. $GL_TPL_FAIL makes the listing fail the way a permission-gated
  # ancestor does, which has to fall through rather than error.
  api)
    case "${2:-}" in
      user) echo '{"username":"tester"}' ;;
      projects/:fullpath)
        printf '{"merge_requests_template":%s}\n' \
          "$([[ -n "${GL_MR_TEMPLATE_SETTING:-}" ]] && jq -Rs . <<<"$GL_MR_TEMPLATE_SETTING" || echo null)" ;;
      projects/*/templates/merge_requests)
        [[ "${GL_TPL_FAIL:-}" == 1 ]] && { echo "stub glab: 403" >&2; exit 1; }
        proj="${2#projects/}"; proj="${proj%%/templates/*}"; proj="${proj//[^[:alnum:]]/_}"
        dir="$GL_TPL_DIR/$proj"
        [[ -d "$dir" ]] || { echo '[]'; exit 0; }
        # $GL_TPL_DUP repeats the listing the way the endpoint does for a group's
        # file-template project, which sees its own templates twice.
        { find "$dir" -maxdepth 1 -name '*.md' -exec basename {} .md \;
          if [[ "${GL_TPL_DUP:-}" == 1 ]]; then
            find "$dir" -maxdepth 1 -name '*.md' -exec basename {} .md \;
          fi
        } | sort | jq -R '{key: ., name: .}' | jq -sc . ;;
      projects/*/templates/merge_requests/*)
        proj="${2#projects/}"; proj="${proj%%/templates/*}"; proj="${proj//[^[:alnum:]]/_}"
        name="${2##*/merge_requests/}"
        # The script percent-encodes the name for the path segment; template
        # names carry spaces, so decode before hitting the fixture.
        name=$(printf '%b' "${name//%/\\x}")
        file="$GL_TPL_DIR/$proj/$name.md"
        [[ -f "$file" ]] || { echo "stub glab: 404 $file" >&2; exit 1; }
        jq -Rs '{name: "'"$name"'", content: .}' < "$file" ;;
      *) echo "stub glab: unhandled api path: ${2:-}" >&2; exit 1 ;;
    esac ;;
  *) echo "stub glab: unhandled command: ${1:-}" >&2; exit 1 ;;
esac
EOF

chmod +x "$bin/gh" "$bin/glab"
export PATH="$bin:$PATH"

# Build a repo whose origin URL reads as <host>, on a pushed feature branch with
# one commit ahead of the default branch — the state the auto-open path needs.
# Echoes the repo path.
make_repo() {
  local host=$1 name=$2 remote repo
  remote="$work/remotes/$name/$host/example/repo.git"
  repo="$work/repos/$name"
  mkdir -p "$(dirname "$remote")" "$(dirname "$repo")"
  git init --quiet --bare "$remote"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config commit.gpgsign false
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "seed"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push --quiet -u origin main
  git -C "$repo" remote set-head origin main
  git -C "$repo" checkout --quiet -b feat
  printf 'change\n' > "$repo/a.txt"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "Add a"
  git -C "$repo" push --quiet -u origin feat
  echo "$repo"
}

key() { sed -n "s/^$2=//p" <<<"$1"; }

export CALL_LOG="$work/calls.log"
export CR_JSON="$work/cr.json"
export CR_AFTER_CREATE="$work/cr-after-create.json"
export DELETE_ON_MERGE=false
export GH_OWNER=example
export GH_REMOTE="$work/gh-remote"
export GL_TPL_DIR="$work/gl-templates"
export GL_MR_TEMPLATE_SETTING=""
export GL_TPL_FAIL=0

# The stubs key their template fixtures by the project token the script passes,
# with every non-alphanumeric character folded to `_` — so the current project
# (`:fullpath`) is `_fullpath`, and an `anchor.crTemplateRepo` of `grp/tpl`
# arrives percent-encoded as `grp%2Ftpl` and lands in `grp_2Ftpl`.
gl_templates() {
  local dir="$GL_TPL_DIR/${1//[^[:alnum:]]/_}" name
  shift
  mkdir -p "$dir"
  for name in "$@"; do printf 'body of %s\n' "$name" > "$dir/$name.md"; done
}

gh_remote_file() {
  local target="$GH_REMOTE/$1"
  mkdir -p "$(dirname "$target")"
  printf 'body of %s\n' "$1" > "$target"
}

# Add files to a repo and land them on the branch the CR head points at, so the
# template lookup runs against a clean tree in the `match` state.
add_files() {
  local repo=$1 rel
  shift
  for rel in "$@"; do
    mkdir -p "$repo/$(dirname "$rel")"
    printf 'template %s\n' "$rel" > "$repo/$rel"
  done
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "Add templates"
  git -C "$repo" push --quiet origin HEAD
}

# A repo already carrying an open CR, so each template case reads a settled
# state rather than re-testing the auto-open path.
template_repo() {
  local host=$1 name=$2 repo
  shift 2
  repo="$(make_repo "$host" "$name")"
  [[ $# -gt 0 ]] && add_files "$repo" "$@"
  if [[ "$host" == github.com ]]; then
    gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
  else
    glab_mr_json "$(git -C "$repo" rev-parse HEAD)" true false
  fi
  cp "$CR_AFTER_CREATE" "$CR_JSON"
  echo "$repo"
}

gh_pr_json() {
  cat > "$CR_AFTER_CREATE" <<JSON
{"url":"https://github.com/example/repo/pull/7","number":7,"isDraft":true,
 "headRefOid":"$1","body":"seeded body"}
JSON
}

glab_mr_json() {
  cat > "$CR_AFTER_CREATE" <<JSON
{"web_url":"https://gitlab.com/example/repo/-/merge_requests/7","iid":7,"draft":true,
 "sha":"$1","description":"seeded body",
 "should_remove_source_branch":$2,"force_remove_source_branch":$3}
JSON
}

# --- GitHub, repo setting off: the opened PR carries no preference -----------
repo="$(make_repo github.com gh-off)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=false
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" CR_CREATED)" == 1 ]] || fail "expected the script to open the PR; got: $out"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == false ]] \
  || fail "expected DELETE_BRANCH_ON_MERGE=false with the repo setting off; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitHub with deleteBranchOnMerge off reports false"

# --- GitHub, repo setting on -------------------------------------------------
repo="$(make_repo github.com gh-on)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=true
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == true ]] \
  || fail "expected true with the repo setting on; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitHub with deleteBranchOnMerge on reports true"

# --- GitHub, the setting read fails: unknown, never a silent false -----------
repo="$(make_repo github.com gh-err)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=error
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == unknown ]] \
  || fail "expected unknown when the setting read fails; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitHub reports unknown when the repo-setting read fails"

# --- GitHub, the setting reads as null: unknown, and the block still lands ---
# A field GitHub answers as null (a permission that hides it, a schema change) is
# neither state. The whole KEY=value block has to survive it — the skill acts on
# the block, so a script that exits early takes the rest of the recon with it.
repo="$(make_repo github.com gh-null)"
: > "$CR_JSON"
gh_pr_json "$(git -C "$repo" rev-parse HEAD)"
export DELETE_ON_MERGE=null
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == unknown ]] \
  || fail "expected unknown for a null setting; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
[[ -n "$(key "$out" FILE_LINKS)" ]] || fail "block truncated after the null setting: $out"
ok "GitHub reports unknown for a null setting without truncating the block"

# --- GitLab: the create call still sets the per-MR flag ----------------------
repo="$(make_repo gitlab.com gl-create)"
: > "$CR_JSON"
: > "$CALL_LOG"
glab_mr_json "$(git -C "$repo" rev-parse HEAD)" true false
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" CR_CREATED)" == 1 ]] || fail "expected the script to open the MR; got: $out"
grep -q 'glab mr create .*--remove-source-branch' "$CALL_LOG" \
  || fail "create call dropped --remove-source-branch: $(cat "$CALL_LOG")"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == true ]] \
  || fail "expected true for an MR created with --remove-source-branch; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitLab sets --remove-source-branch at create and reports true"

# --- GitLab, a pre-existing MR with the flag unset --------------------------
repo="$(make_repo gitlab.com gl-unset)"
glab_mr_json "$(git -C "$repo" rev-parse HEAD)" false false
cp "$CR_AFTER_CREATE" "$CR_JSON"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" CR_PREEXISTING)" == 1 ]] || fail "expected the MR to resolve as pre-existing; got: $out"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == false ]] \
  || fail "expected false for an MR with the flag unset; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitLab reports false for a pre-existing MR with the flag unset"

# --- GitLab, project settings force the removal -----------------------------
repo="$(make_repo gitlab.com gl-forced)"
glab_mr_json "$(git -C "$repo" rev-parse HEAD)" false true
cp "$CR_AFTER_CREATE" "$CR_JSON"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == true ]] \
  || fail "expected true when force_remove_source_branch is set; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "GitLab reports true when the project forces branch removal"

# --- No forge: nothing to report -------------------------------------------
repo="$(make_repo example.invalid no-forge)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" FORGE)" == none ]] || fail "expected FORGE=none; got: $out"
[[ "$(key "$out" DELETE_BRANCH_ON_MERGE)" == unknown ]] \
  || fail "expected unknown with no forge; got: $(key "$out" DELETE_BRANCH_ON_MERGE)"
ok "no forge reports unknown"

# --- Template resolution ------------------------------------------------------

export GL_TPL_DUP=0
tpl_reset() { rm -rf "$GL_TPL_DIR" "$GH_REMOTE"; GL_MR_TEMPLATE_SETTING=""; GL_TPL_FAIL=0; GL_TPL_DUP=0; }

# --- GitLab: a repo-local template still beats an inherited one --------------
tpl_reset
gl_templates :fullpath default
repo="$(template_repo gitlab.com tpl-gl-local .gitlab/merge_request_templates/Merge_Request.md)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == local ]] \
  || fail "expected the repo-local template to win; got: $(key "$out" TEMPLATE_SOURCE)"
[[ "$(key "$out" TEMPLATE_PATH)" == /*/.gitlab/merge_request_templates/Merge_Request.md ]] \
  || fail "expected an absolute local path; got: $(key "$out" TEMPLATE_PATH)"
ok "GitLab prefers a repo-local template over an inherited one"

# --- GitLab: no local template, so the inherited one resolves ----------------
tpl_reset
gl_templates :fullpath default
repo="$(template_repo gitlab.com tpl-gl-inherited)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == inherited ]] \
  || fail "expected the inherited template; got: $(key "$out" TEMPLATE_SOURCE)"
grep -q 'body of default' "$(key "$out" TEMPLATE_PATH)" \
  || fail "inherited template body not fetched: $(cat "$(key "$out" TEMPLATE_PATH)")"
ok "GitLab resolves an inherited template when the repo ships none"

# --- GitLab: the project's own setting outranks every file source ------------
tpl_reset
GL_MR_TEMPLATE_SETTING="## From project settings"
repo="$(template_repo gitlab.com tpl-gl-setting .gitlab/merge_request_templates/default.md)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == project-settings ]] \
  || fail "expected the project setting to win; got: $(key "$out" TEMPLATE_SOURCE)"
grep -q 'From project settings' "$(key "$out" TEMPLATE_PATH)" \
  || fail "project-settings body not written: $(key "$out" TEMPLATE_PATH)"
ok "GitLab prefers the project-settings template over file templates"

# --- A level holding several templates picks default.md, not glob order ------
tpl_reset
repo="$(template_repo gitlab.com tpl-gl-default \
  .gitlab/merge_request_templates/aaa.md \
  .gitlab/merge_request_templates/default.md \
  .gitlab/merge_request_templates/zzz.md)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_PATH)" == /*/.gitlab/merge_request_templates/default.md ]] \
  || fail "expected default.md to win the level; got: $(key "$out" TEMPLATE_PATH)"
ok "default.md wins a level holding several templates"

# --- Several templates and no default: the author picks ----------------------
tpl_reset
repo="$(template_repo gitlab.com tpl-gl-ambiguous \
  .gitlab/merge_request_templates/hotfix.md \
  .gitlab/merge_request_templates/refactor.md)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == ambiguous ]] \
  || fail "expected ambiguous with no default.md; got: $(key "$out" TEMPLATE_SOURCE)"
[[ -z "$(key "$out" TEMPLATE_PATH)" ]] \
  || fail "expected no template picked; got: $(key "$out" TEMPLATE_PATH)"
[[ "$(key "$out" TEMPLATE_CANDIDATES | jq -r '[.[].name] | sort | join(",")')" == hotfix,refactor ]] \
  || fail "expected both candidates; got: $(key "$out" TEMPLATE_CANDIDATES)"
ok "a level with several templates and no default hands the author candidates"

# --- The duplicated listing a file-template project returns is one template --
tpl_reset
GL_TPL_DUP=1
gl_templates :fullpath default
repo="$(template_repo gitlab.com tpl-gl-dup)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == inherited ]] \
  || fail "expected the duplicate listing to resolve to one template; got: $(key "$out" TEMPLATE_SOURCE)"
ok "a duplicated template listing resolves rather than reading as ambiguous"

# --- A permission-gated level falls through instead of failing the run -------
tpl_reset
GL_TPL_FAIL=1
repo="$(template_repo gitlab.com tpl-gl-403)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == none ]] \
  || fail "expected none when the lookup is gated; got: $(key "$out" TEMPLATE_SOURCE)"
[[ -n "$(key "$out" FILE_LINKS)" ]] || fail "block truncated by the gated lookup: $out"
ok "a gated template lookup falls through without truncating the block"

# --- anchor.crTemplateRepo is the backstop when nothing else answers ---------
tpl_reset
gl_templates 'grp%2Ftpl' default
repo="$(template_repo gitlab.com tpl-gl-configured)"
git -C "$repo" config anchor.crTemplateRepo 'grp/tpl'
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == configured ]] \
  || fail "expected the configured template repo; got: $(key "$out" TEMPLATE_SOURCE)"
ok "anchor.crTemplateRepo backstops an empty hierarchy"

# --- GitHub: the root and docs/ paths GitHub honors but anchor used to miss --
for loc in pull_request_template.md docs/pull_request_template.md; do
  tpl_reset
  repo="$(template_repo github.com "tpl-gh-${loc//\//-}" "$loc")"
  out=$(bash "$prepare_review_sh" --repo "$repo")
  [[ "$(key "$out" TEMPLATE_PATH)" == "/"*"/$loc" ]] \
    || fail "expected $loc to resolve absolutely; got: $(key "$out" TEMPLATE_PATH)"
  ok "GitHub resolves a template at $loc"
done

# --- GitHub: the owner's .github repo is the one inherited source ------------
tpl_reset
gh_remote_file "example/.github/.github/pull_request_template.md"
repo="$(template_repo github.com tpl-gh-inherited)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == inherited ]] \
  || fail "expected the owner .github template; got: $(key "$out" TEMPLATE_SOURCE)"
ok "GitHub falls back to the owner's .github repo"

# --- GitHub: a repo-local template still wins over the owner default ---------
tpl_reset
gh_remote_file "example/.github/.github/pull_request_template.md"
repo="$(template_repo github.com tpl-gh-local-wins .github/pull_request_template.md)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == local ]] \
  || fail "expected the repo-local template to win; got: $(key "$out" TEMPLATE_SOURCE)"
ok "GitHub prefers a repo-local template over the owner's default"

# --- Nothing anywhere: unchanged behavior, no template ----------------------
tpl_reset
repo="$(template_repo github.com tpl-gh-none)"
out=$(bash "$prepare_review_sh" --repo "$repo")
[[ "$(key "$out" TEMPLATE_SOURCE)" == none ]] \
  || fail "expected none for an empty hierarchy; got: $(key "$out" TEMPLATE_SOURCE)"
[[ -z "$(key "$out" TEMPLATE_PATH)" ]] \
  || fail "expected no template path; got: $(key "$out" TEMPLATE_PATH)"
ok "an empty hierarchy leaves the template unset"

echo "all prepare-review tests passed"
