#!/usr/bin/env bash
# A fake GitHub behind the gh stub for the remote contribute tests (installed
# with `ds_stub_override gh`, so the stub records every call first). The
# repositories are the local bare repositories listed in
# DS_TEST_ROOT/hub/repos ("owner/repo<TAB>bare path" lines); pull requests,
# workflow runs and releases live in DS_TEST_ROOT/hub. Not a test file.
#
# Knobs (DS_TEST_ROOT/hub/knobs/NAME, see hub_knob in helpers.sh):
#   push           push permission on every repository (default true)
#   actions        GitHub Actions enabled (default true)
#   checks         pull request checks: pass, fail or none (default pass)
#   ci             the synthetic push run of ci.yml on every pushed commit:
#                  success, failure or none (default success)
#   clean-install  conclusion of a dispatched clean-install.yml run
#                  (default success)
#   merge          normal, race (a concurrent commit lands on main just
#                  before the squash) or refuse (default normal)
#   ci-moves-main  a file name: while `pr checks --watch` runs, a commit
#                  writing that file lands on main (once)
#
# Supported commands (--jq/-q FILTER is applied to the JSON answer):
#   auth status; api user; config get git_protocol; api repos/R;
#   api repos/R/actions/permissions; api -X GET repos/R/actions/runs
#   -f head_sha=S ...; api repos/R/actions/runs/ID; workflow run W -R R
#   --ref B; pr list -R R --head B ...; pr create -R R --base main --head
#   [OWNER:]B --title T --body B; pr view URL; pr checks URL --json name |
#   --watch ...; pr merge URL --squash --match-head-commit SHA; release
#   view TAG -R R; release create TAG -R R ... --verify-tag
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

case "${1:-} ${2:-}" in
  "auth status")
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
    find "$hub/runs" -name '*.json' -exec cat {} + |
      jq -s --arg repo "$repo" --arg sha "$sha" '{workflow_runs: [.[] | select(.repo == $repo and .head_sha == $sha)]}' |
      answer
    ;;
  "api "*)
    path=$2
    if [[ $path =~ ^repos/([^/]+/[^/]+)/actions/permissions$ ]]; then
      jq -n --argjson enabled "$(knob actions true)" '{enabled: $enabled}' | answer
    elif [[ $path =~ ^repos/([^/]+/[^/]+)/actions/runs/([0-9]+)$ ]]; then
      [[ -f $hub/runs/${BASH_REMATCH[2]}.json ]] || fail "gh: Not Found (HTTP 404)"
      answer <"$hub/runs/${BASH_REMATCH[2]}.json"
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
    jq --arg head "$head" '{url, state, headRefOid: $head,
      mergeCommit: (if .merge_commit then {oid: .merge_commit} else null end)}' "$file" | answer
    ;;
  "pr checks")
    pr_file_of "$3" >/dev/null
    state=$(knob checks pass)
    if [[ " ${args[*]} " == *" --watch "* ]]; then
      case $state in
        pass)
          if [[ -f $hub/knobs/ci-moves-main ]]; then
            move_main "$(jq -r .repo "$(pr_file_of "$3")")" "$(<"$hub/knobs/ci-moves-main")"
            rm -f "$hub/knobs/ci-moves-main"
          fi
          printf 'All checks were successful\nci\tpass\t1m\n'
          ;;
        fail)
          printf 'Some checks were not successful\nci\tfail\t1m\n'
          exit 1
          ;;
        *) fail "no checks reported on the branch" ;;
      esac
    elif [[ $state == none ]]; then
      jq -n '[]' | answer
    else
      jq -n --arg state "$state" '[{name: "ci", bucket: $state}]' | answer
    fi
    ;;
  "pr merge")
    file=$(pr_file_of "$3")
    expected=$(option --match-head-commit) || fail "fake gh: pr merge needs --match-head-commit"
    [[ " ${args[*]} " == *" --squash "* ]] || fail "fake gh: pr merge needs --squash"
    [[ $(knob merge normal) != refuse ]] || fail "GraphQL: Pull request is not mergeable"
    [[ $(jq -r .state "$file") == OPEN ]] || fail "GraphQL: Pull request is not open"
    repo=$(jq -r .repo "$file")
    bare=$(bare_of "$repo")
    head=$(tip_of "$(bare_of "$(jq -r .head_repo "$file")")" "$(jq -r .head_branch "$file")")
    [[ $head == "$expected" ]] || fail "GraphQL: Head branch was modified. Review and try the merge again."
    work=$(mktemp -d "$DS_TEST_ROOT/merge.XXXXXX")
    git clone -q "$bare" "$work"
    git -C "$work" fetch -q "$(bare_of "$(jq -r .head_repo "$file")")" "$head"
    if [[ $(knob merge normal) == race ]]; then
      move_main "$repo" concurrent.txt
      git -C "$work" pull -q --ff-only origin main
    fi
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
    [[ " ${args[*]} " == *" --verify-tag "* ]] || fail "fake gh: release create needs --verify-tag"
    git -C "$bare" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || fail "tag $tag doesn't exist in the repo"
    [[ ! -f $hub/releases/${repo//\//_}_$tag ]] || fail "a release with the same tag name already exists"
    printf '%s\n' "${args[*]}" >"$hub/releases/${repo//\//_}_$tag"
    printf 'https://github.com/%s/releases/tag/%s\n' "$repo" "$tag"
    ;;
  *)
    fail "fake gh: unsupported: $*"
    ;;
esac
