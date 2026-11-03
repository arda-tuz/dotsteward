#!/usr/bin/env bash
# A fake GitHub behind the gh stub for the remote contribute tests (installed
# with `ds_stub_override gh`, so the stub records every call first). The
# repositories are the local bare repositories listed in
# DS_TEST_ROOT/hub/repos ("owner/repo<TAB>bare path" lines); pull requests,
# workflow runs and releases live in DS_TEST_ROOT/hub. Not a test file.
#
# Knobs (DS_TEST_ROOT/hub/knobs/NAME, see hub_knob in helpers.sh):
#   push           push permission on every repository (default true)
#   logged-out     true: `gh auth status` fails, as without a login
#   actions        GitHub Actions enabled (default true)
#   checks         pull request checks: pass, fail, pending or none
#                  (default pass), the bucket of lint (ci) and generic
#                  (privacy); the knobs lint and generic set one of them
#   full-check     the bucket of the full check (check of ci) on a pull
#                  request: skipping (default, as the CI runs it only on
#                  main and for forks), pending, pass or fail; denylist
#                  (privacy) is always skipping
#   ci             the synthetic push run of ci.yml on every pushed commit:
#                  success, failure or none (default success)
#   main-ci        the push runs of ci.yml and privacy.yml on main for a
#                  commit on main (main's CI): success, failure or none
#                  (default success); main-ci-WORKFLOW (main-ci-ci.yml,
#                  main-ci-privacy.yml) sets one of them
#   main-ci-pending a count: the run of main's CI reads in_progress (in a
#                  listing, and in that many reads by id, which count it
#                  down) before it concludes
#   release-workflow "TAG [COMMIT]": once a run of main's CI is read by id
#                  as concluded with success, the release workflow cuts
#                  TAG as `tools/version.sh release` does with gh release
#                  create --target: a lightweight tag on COMMIT (default:
#                  the commit of that run) and its GitHub release (once)
#   release-race   any value: the next `release create` finds the GitHub
#                  release that the release workflow created just before,
#                  and fails as GitHub does (once)
#   clean-install  conclusion of a dispatched clean-install.yml run
#                  (default success)
#   ci-moves-main  a file name: while the checks run (at the green
#                  `pr checks` answer with buckets), a commit writing that
#                  file lands on main (once)
#   ci-tags        a tag name: while the checks run (as above), that tag
#                  (annotated) lands on main of the repository (once)
#   stale-head     a count: the next that many `pr view` and `pr checks`
#                  calls answer for the head the pull request had before
#                  the last push (headRefOid 1111...; lint failed there),
#                  as GitHub does for a moment after a push
#   checks-later   a count: the next that many `pr checks` calls (after any
#                  stale-head calls) find no check on the new head yet
#   checks-flaky   a count: the next that many `pr checks` calls with
#                  buckets fail with HTTP 502, as GitHub's API does at times
#   checks-pending a count: the next that many `pr checks` calls with
#                  buckets find lint and generic still pending
#
# Supported commands (--jq/-q FILTER is applied to the JSON answer):
#   auth status; api user; config get git_protocol; api repos/R;
#   api repos/R/actions/permissions; api -X GET repos/R/actions/runs
#   -f head_sha=S ...; api repos/R/actions/runs/ID; workflow run W -R R
#   --ref B; pr list -R R --head B ...; pr create -R R --base main --head
#   [OWNER:]B --title T --body B; pr view URL; pr checks URL --json FIELDS
#   (name, workflow, event, bucket); pr merge URL --squash --match-head-commit SHA (a merge
#   made on GitHub by hand: a new squash commit on main); release view TAG
#   -R R; release create TAG -R R ... --verify-tag | --target SHA (a missing
#   tag is created there, lightweight) [--notes-file FILE] (kept next to the
#   release as <release>.notes); every -R also as --repo; workflow run
#   also on a tag
#
# An open pull request whose head commit is on its base branch (main was
# fast-forwarded to it by a push) is recorded as merged with that head as
# its merge commit, as GitHub does.
set -euo pipefail

hub=$DS_TEST_ROOT/hub
mkdir -p "$hub/prs" "$hub/runs" "$hub/releases"

filter=""
args=()
while (($#)); do
  case $1 in
    --jq | -q)
      filter=$2
      shift 2
      continue
      ;;
    *) args+=("$1") ;;
  esac
  shift
done
set -- "${args[@]}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

knob() {
  if [[ -f $hub/knobs/$1 ]]; then
    tr -d '\n' <"$hub/knobs/$1"
  else
    printf '%s' "$2"
  fi
}

# answer: the JSON document on standard input, through the --jq filter.
answer() {
  if [[ -n $filter ]]; then
    jq -r "$filter"
  else
    cat
  fi
}

# option NAME: the value after NAME in the arguments.
option() {
  local i
  for ((i = 0; i < ${#args[@]} - 1; i++)); do
    if [[ ${args[i]} == "$1" ]]; then
      printf '%s\n' "${args[i + 1]}"
      return 0
    fi
  done
  return 1
}

repo_option() {
  option -R || option --repo || fail "fake gh: no -R in: ${args[*]}"
}

bare_of() {
  local bare
  bare=$(awk -F'\t' -v slug="$1" 'tolower($1) == tolower(slug) { print $2 }' "$hub/repos")
  [[ -n $bare ]] || return 1
  printf '%s\n' "$bare"
}

tip_of() {
  git -C "$1" rev-parse --verify --quiet "refs/heads/$2^{commit}" || true
}

pr_file_of() {
  local url=$1 file
  for file in "$hub"/prs/*.json; do
    [[ -f $file ]] || continue
    if [[ $(jq -r .url "$file") == "$url" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  fail "GraphQL: Could not resolve to a PullRequest ($url)"
}

next_id() {
  local dir=$1 count
  count=$(find "$dir" -maxdepth 1 -name '*.json' | wc -l)
  printf '%s\n' "$((${count//[[:space:]]/} + $2))"
}

# move_main REPO FILE: a commit that writes FILE lands on main of REPO.
move_main() {
  local work
  work=$(mktemp -d "$DS_TEST_ROOT/move.XXXXXX")
  git clone -q "$(bare_of "$1")" "$work"
  printf '%s\n' "$2" >"$work/$2"
  git -C "$work" add -A
  git -C "$work" commit -q -m "chore: a concurrent change"
  git -C "$work" push -q origin HEAD:main
  rm -rf -- "$work"
}

# synthetic_ci REPO SHA: the push run of ci.yml for a pushed commit, as the
# knob ci says now (written again on every listing, removed for none).
synthetic_ci() {
  local repo=$1 sha=$2 conclusion bare branch="" id file
  bare=$(bare_of "$repo") || return 0
  id=$((900000 + $(printf '%s' "$repo$sha" | cksum | cut -d' ' -f1) % 99999))
  file=$hub/runs/$id.json
  conclusion=$(knob ci success)
  branch=$(git -C "$bare" for-each-ref --points-at "$sha" --format='%(refname:short)' refs/heads | head -n 1)
  if [[ $conclusion == none || -z $branch ]]; then
    rm -f -- "$file"
    return 0
  fi
  jq -n --argjson id "$id" --arg repo "$repo" --arg sha "$sha" --arg branch "$branch" \
    --arg conclusion "$conclusion" '{id: $id, repo: $repo, path: ".github/workflows/ci.yml", event: "push",
      head_sha: $sha, head_branch: $branch, status: "completed", conclusion: $conclusion,
      created_at: "2026-01-01T00:00:00Z", html_url: "https://github.com/\($repo)/actions/runs/\($id)"}' >"$file"
}

# synthetic_main_ci REPO SHA: main's CI for a commit on main of REPO, the
# push runs of ci.yml and privacy.yml (head_branch main), as the knobs
# main-ci and main-ci-WORKFLOW say now (written again on every listing,
# removed for none or a commit that is not on main).
synthetic_main_ci() {
  local repo=$1 sha=$2 bare workflow id file conclusion
  bare=$(bare_of "$repo") || return 0
  for workflow in ci.yml privacy.yml; do
    id=$((800000 + $(printf '%s' "$repo$sha$workflow" | cksum | cut -d' ' -f1) % 99999))
    file=$hub/runs/$id.json
    conclusion=$(knob "main-ci-$workflow" "$(knob main-ci success)")
    if [[ $conclusion == none || -z $sha ]] ||
      ! git -C "$bare" merge-base --is-ancestor "$sha" refs/heads/main 2>/dev/null; then
      rm -f -- "$file"
      continue
    fi
    jq -n --argjson id "$id" --arg repo "$repo" --arg sha "$sha" --arg path ".github/workflows/$workflow" \
      --arg conclusion "$conclusion" --argjson pending "$(knob main-ci-pending 0)" '{id: $id, repo: $repo,
        path: $path, event: "push", head_sha: $sha, head_branch: "main", synthetic: "main",
        status: (if $pending > 0 then "in_progress" else "completed" end),
        conclusion: (if $pending > 0 then null else $conclusion end), created_at: "2026-01-01T00:00:01Z",
        html_url: "https://github.com/\($repo)/actions/runs/\($id)", final: $conclusion}' >"$file"
  done
}

# release_workflow RUN_FILE: the knob release-workflow, once the run of
# main's CI in RUN_FILE concluded with success: the tag and the GitHub
# release the release workflow makes (once).
release_workflow() {
  local file=$1 knob=$hub/knobs/release-workflow tag target="" repo bare
  [[ -f $knob && $(jq -r .final "$file") == success ]] || return 0
  read -r tag target <"$knob"
  rm -f -- "$knob"
  repo=$(jq -r .repo "$file")
  bare=$(bare_of "$repo")
  [[ -n $target ]] || target=$(jq -r .head_sha "$file")
  git -C "$bare" tag "$tag" "$target"
  printf 'release create %s --repo %s --target %s (the release workflow)\n' "$tag" "$repo" "$target" \
    >"$hub/releases/${repo//\//_}_$tag"
}

# sync_prs: every open pull request whose head commit is on its base branch
# becomes merged, with the head as its merge commit.
sync_prs() {
  local file head base_bare
  for file in "$hub"/prs/*.json; do
    [[ -f $file && $(jq -r .state "$file") == OPEN ]] || continue
    head=$(tip_of "$(bare_of "$(jq -r .head_repo "$file")")" "$(jq -r .head_branch "$file")")
    base_bare=$(bare_of "$(jq -r .repo "$file")")
    [[ -n $head ]] || continue
    git -C "$base_bare" merge-base --is-ancestor "$head" "refs/heads/$(jq -r .base "$file")" 2>/dev/null || continue
    jq --arg head "$head" '.state = "MERGED" | .merge_commit = $head' "$file" >"$file.new"
    mv "$file.new" "$file"
  done
}
sync_prs

# consume NAME: true while the counter knob NAME is above zero, counting it
# down (the knob is removed at zero).
consume() {
  local file=$hub/knobs/$1 count
  [[ -f $file ]] || return 1
  count=$(tr -d '\n' <"$file")
  if ((count <= 1)); then
    rm -f -- "$file"
  else
    printf '%s\n' "$((count - 1))" >"$file"
  fi
  ((count >= 1))
}
stale_head=1111111111111111111111111111111111111111

case "${1:-} ${2:-}" in
  "auth status")
    [[ $(knob logged-out false) != true ]] || fail "You are not logged into any GitHub hosts. To log in, run: gh auth login"
    printf 'github.com\n  - Logged in to github.com account dotsteward-test (keyring)\n'
    ;;
  "api user")
    jq -n '{login: "dotsteward-test", id: 1000}' | answer
    ;;
  "config get")
    printf 'ssh\n'
    ;;
  "api -X")
    path=$4
    [[ $path =~ ^repos/([^/]+/[^/]+)/actions/runs$ ]] || fail "fake gh: unsupported: $*"
    repo=${BASH_REMATCH[1]}
    sha=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ ${args[i]} == -f && ${args[i + 1]} == head_sha=* ]]; then
        sha=${args[i + 1]#head_sha=}
      fi
    done
    synthetic_ci "$repo" "$sha"
    synthetic_main_ci "$repo" "$sha"
    find "$hub/runs" -name '*.json' -exec cat {} + |
      jq -s --arg repo "$repo" --arg sha "$sha" '{workflow_runs: [.[] | select(.repo == $repo and .head_sha == $sha)]}' |
      answer
    ;;
  "api "*)
    path=$2
    if [[ $path =~ ^repos/([^/]+/[^/]+)/actions/permissions$ ]]; then
      jq -n --argjson enabled "$(knob actions true)" '{enabled: $enabled}' | answer
    elif [[ $path =~ ^repos/([^/]+/[^/]+)/actions/runs/([0-9]+)$ ]]; then
      file=$hub/runs/${BASH_REMATCH[2]}.json
      [[ -f $file ]] || fail "gh: Not Found (HTTP 404)"
      if [[ $(jq -r '.synthetic // ""' "$file") == main ]]; then
        # main's CI concludes once main-ci-pending ran out.
        if consume main-ci-pending; then
          jq '.status = "in_progress" | .conclusion = null' "$file" | answer
        else
          release_workflow "$file"
          jq '.status = "completed" | .conclusion = .final' "$file" | answer
        fi
      else
        answer <"$file"
      fi
    elif [[ $path =~ ^repos/([^/]+/[^/]+)$ ]]; then
      bare_of "${BASH_REMATCH[1]}" >/dev/null || fail "gh: Not Found (HTTP 404)"
      jq -n --arg slug "${BASH_REMATCH[1]}" --argjson push "$(knob push true)" \
        '{full_name: $slug, fork: false, permissions: {admin: false, push: $push, pull: true}}' | answer
    else
      fail "fake gh: unsupported: $*"
    fi
    ;;
  "workflow run")
    workflow=$3
    repo=$(repo_option)
    ref=$(option --ref) || fail "fake gh: workflow run needs --ref"
    [[ $(knob actions true) == true ]] || fail "HTTP 403: Actions are disabled for this repository"
    bare=$(bare_of "$repo") || fail "gh: Not Found (HTTP 404)"
    sha=$(tip_of "$bare" "$ref")
    [[ -n $sha ]] || sha=$(git -C "$bare" rev-parse --verify --quiet "refs/tags/$ref^{commit}" || true)
    [[ -n $sha ]] || fail "HTTP 422: No ref found for: $ref"
    id=$(next_id "$hub/runs" 1000)
    jq -n --argjson id "$id" --arg repo "$repo" --arg path ".github/workflows/$workflow" --arg sha "$sha" \
      --arg branch "$ref" --arg conclusion "$(knob clean-install success)" '{id: $id, repo: $repo, path: $path,
        event: "workflow_dispatch", head_sha: $sha, head_branch: $branch, status: "completed",
        conclusion: $conclusion, created_at: "2026-01-02T00:00:00Z",
        html_url: "https://github.com/\($repo)/actions/runs/\($id)"}' >"$hub/runs/$id.json"
    ;;
  "pr list")
    repo=$(repo_option)
    head=$(option --head) || fail "fake gh: pr list needs --head"
    find "$hub/prs" -name '*.json' -exec cat {} + |
      jq -s --arg repo "$repo" --arg head "$head" '[.[] | select(.repo == $repo and .head_branch == $head
        and .state == "OPEN") | {url, headRepositoryOwner: {login: (.head_repo | split("/")[0])}}]' |
      answer
    ;;
  "pr create")
    repo=$(repo_option)
    head=$(option --head) || fail "fake gh: pr create needs --head"
    base=$(option --base) || fail "fake gh: pr create needs --base"
    title=$(option --title) || fail "fake gh: pr create needs --title"
    body=$(option --body) || fail "fake gh: pr create needs --body"
    head_repo=$repo
    branch=$head
    if [[ $head == *:* ]]; then
      head_repo=${head%%:*}/${repo#*/}
      branch=${head#*:}
    fi
    bare=$(bare_of "$head_repo") || fail "fake gh: unknown head repository $head_repo"
    [[ -n $(tip_of "$bare" "$branch") ]] || fail "pull request create failed: Head sha can't be blank"
    number=$(next_id "$hub/prs" 1)
    url=https://github.com/$repo/pull/$number
    jq -n --argjson number "$number" --arg url "$url" --arg repo "$repo" --arg head_repo "$head_repo" \
      --arg branch "$branch" --arg base "$base" --arg title "$title" --arg body "$body" \
      '{number: $number, url: $url, repo: $repo, head_repo: $head_repo, head_branch: $branch, base: $base,
        title: $title, body: $body, state: "OPEN", merge_commit: null}' >"$hub/prs/$number.json"
    printf '%s\n' "$url"
    ;;
  "pr view")
    file=$(pr_file_of "$3")
    bare=$(bare_of "$(jq -r .head_repo "$file")")
    head=$(tip_of "$bare" "$(jq -r .head_branch "$file")")
    if consume stale-head; then
      head=$stale_head
    fi
    jq --arg head "$head" '{url, state, headRefOid: $head,
      mergeCommit: (if .merge_commit then {oid: .merge_commit} else null end)}' "$file" | answer
    ;;
  "pr checks")
    pr_file_of "$3" >/dev/null
    state=$(knob checks pass)
    if consume stale-head; then
      jq -n '[{name: "lint", workflow: "ci", event: "pull_request", bucket: "fail"},
        {name: "generic", workflow: "privacy", event: "pull_request", bucket: "pass"}]' | answer
      exit 0
    fi
    if consume checks-later; then
      state=none
    fi
    if [[ " ${args[*]} " == *bucket* ]]; then
      consume checks-flaky && fail "HTTP 502: 502 Bad Gateway (https://api.github.com/graphql)"
      if consume checks-pending; then
        state=pending
      fi
      if [[ $state == pass ]]; then
        if [[ -f $hub/knobs/ci-moves-main ]]; then
          move_main "$(jq -r .repo "$(pr_file_of "$3")")" "$(<"$hub/knobs/ci-moves-main")"
          rm -f "$hub/knobs/ci-moves-main"
        fi
        if [[ -f $hub/knobs/ci-tags ]]; then
          tag=$(<"$hub/knobs/ci-tags")
          git -C "$(bare_of "$(jq -r .repo "$(pr_file_of "$3")")")" tag -a "$tag" -m "dotsteward $tag" refs/heads/main
          rm -f "$hub/knobs/ci-tags"
        fi
      fi
    fi
    if [[ $state == none ]]; then
      jq -n '[]' | answer
    else
      # The checks of the pull request head: the jobs of ci.yml and
      # privacy.yml (gh names a check by its job and its workflow).
      jq -n --arg lint "$(knob lint "$state")" --arg generic "$(knob generic "$state")" \
        --arg full "$(knob full-check skipping)" '[
          {name: "lint", workflow: "ci", event: "pull_request", bucket: $lint},
          {name: "check", workflow: "ci", event: "pull_request", bucket: $full},
          {name: "generic", workflow: "privacy", event: "pull_request", bucket: $generic},
          {name: "denylist", workflow: "privacy", event: "pull_request", bucket: "skipping"}]' | answer
    fi
    ;;
  "pr merge")
    file=$(pr_file_of "$3")
    expected=$(option --match-head-commit) || fail "fake gh: pr merge needs --match-head-commit"
    [[ " ${args[*]} " == *" --squash "* ]] || fail "fake gh: pr merge needs --squash"
    [[ $(jq -r .state "$file") == OPEN ]] || fail "GraphQL: Pull request is not open"
    repo=$(jq -r .repo "$file")
    bare=$(bare_of "$repo")
    head=$(tip_of "$(bare_of "$(jq -r .head_repo "$file")")" "$(jq -r .head_branch "$file")")
    [[ $head == "$expected" ]] || fail "GraphQL: Head branch was modified. Review and try the merge again."
    work=$(mktemp -d "$DS_TEST_ROOT/merge.XXXXXX")
    git clone -q "$bare" "$work"
    git -C "$work" fetch -q "$(bare_of "$(jq -r .head_repo "$file")")" "$head"
    git -C "$work" merge -q --squash "$head" >/dev/null
    git -C "$work" commit -q -m "$(jq -r '"\(.title) (#\(.number))"' "$file")"
    git -C "$work" push -q origin HEAD:main
    merged=$(git -C "$work" rev-parse HEAD)
    rm -rf -- "$work"
    jq --arg merged "$merged" '.state = "MERGED" | .merge_commit = $merged' "$file" >"$file.new"
    mv "$file.new" "$file"
    ;;
  "release view")
    repo=$(repo_option)
    [[ -f $hub/releases/${repo//\//_}_$3 ]] || fail "release not found"
    jq -n --arg tag "$3" '{tagName: $tag}' | answer
    ;;
  "release create")
    tag=$3
    repo=$(repo_option)
    bare=$(bare_of "$repo") || fail "gh: Not Found (HTTP 404)"
    if [[ -f $hub/knobs/release-race ]]; then
      rm -f -- "$hub/knobs/release-race"
      printf 'release create %s --repo %s (the release workflow)\n' "$tag" "$repo" >"$hub/releases/${repo//\//_}_$tag"
    fi
    [[ ! -f $hub/releases/${repo//\//_}_$tag ]] || fail "a release with the same tag name already exists"
    if [[ " ${args[*]} " == *" --verify-tag "* ]]; then
      git -C "$bare" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || fail "tag $tag doesn't exist in the repo"
    elif ! git -C "$bare" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
      # GitHub creates a missing tag (a lightweight one) at --target.
      target=$(option --target) || fail "fake gh: release create of a new tag needs --verify-tag or --target"
      git -C "$bare" cat-file -e "$target^{commit}" 2>/dev/null || fail "HTTP 422: Validation Failed (target_commitish)"
      git -C "$bare" tag "$tag" "$target"
    fi
    printf '%s\n' "${args[*]}" >"$hub/releases/${repo//\//_}_$tag"
    if notes=$(option --notes-file); then
      cp -- "$notes" "$hub/releases/${repo//\//_}_$tag.notes"
    fi
    printf 'https://github.com/%s/releases/tag/%s\n' "$repo" "$tag"
    ;;
  *)
    fail "fake gh: unsupported: $*"
    ;;
esac
