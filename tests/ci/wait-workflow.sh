#!/usr/bin/env bash
# Waits for the newest GitHub Actions run of a workflow on the commit that a
# branch of the remote origin points at, and succeeds only when that run
# concluded with success. A push run of that commit is preferred over runs of
# other events (manual dispatches, pull requests), so a red dispatch run on
# the same commit never hides a green push run; runs of any event count only
# when the commit has no push run, as for a workflow without a push trigger.
#
# Usage: tests/ci/wait-workflow.sh WORKFLOW BRANCH
#
#   WORKFLOW  workflow file name, for example ci.yml
#   BRANCH    branch on origin; its tip is read with git ls-remote, so the
#             run that is waited for belongs to what was pushed, never to an
#             older commit or to the local checkout
#
# Environment (seconds):
#   DS_WAIT_APPEAR    how long a missing run may take to appear (default 300)
#   DS_WAIT_TIMEOUT   how long the run may take to complete (default 3600)
#   DS_WAIT_INTERVAL  polling interval (default 15)
#
# Needs git and an authenticated gh. The repository is the GitHub repository
# of the remote origin. Exit 0 when the run succeeded, 1 otherwise (failure,
# cancellation, no run, timeout or error); the run URL is always printed.
set -Eeuo pipefail

die() {
  printf '[dotsteward] ERROR: wait-workflow: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] wait-workflow: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
esac
(($# == 2)) && [[ -n $1 && -n $2 ]] || die "usage: wait-workflow.sh WORKFLOW BRANCH"
workflow=$1
branch=$2
# The name is embedded in a jq filter below.
[[ $workflow =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || die "WORKFLOW must be a workflow file name such as ci.yml"

# seconds NAME DEFAULT: a positive integer from the environment.
seconds() {
  local value=${!1:-$2}
  [[ $value =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive number of seconds"
  printf '%s' "$value"
}
appear=$(seconds DS_WAIT_APPEAR 300)
timeout=$(seconds DS_WAIT_TIMEOUT 3600)
interval=$(seconds DS_WAIT_INTERVAL 15)

command -v gh >/dev/null 2>&1 || die "gh is required"
origin_url=$(git remote get-url origin 2>/dev/null) || die "no remote named origin"
repo=$(gh repo view "$origin_url" --json nameWithOwner --jq .nameWithOwner) ||
  die "origin is not a GitHub repository gh can read"

sha=$(git ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) ||
  die "branch $branch does not exist on origin"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "unexpected answer from git ls-remote for $branch"
what="$workflow on $branch (${sha:0:12})"

# The REST API is used directly: unlike `gh run list --workflow`, it also
# finds runs of a workflow that does not exist on the default branch yet.

# newest_run: prints "id<TAB>status<TAB>url<TAB>conclusion" of the newest push
# run of the workflow for the branch tip, else of its newest run of any
# event, or nothing when there is none yet.
newest_run() {
  gh api -X GET "repos/$repo/actions/runs" -f branch="$branch" -f head_sha="$sha" -F per_page=100 \
    --jq "[.workflow_runs[] | select((.path | split(\"@\")[0]) == \".github/workflows/$workflow\")]
      | [.[] | select(.event == \"push\")] as \$push | if (\$push | length) > 0 then \$push else . end
      | sort_by(.created_at) | last // empty
      | [.id, .status, .html_url, (.conclusion // \"none\")] | @tsv"
}

start=$SECONDS
run=""
while :; do
  run=$(newest_run) || die "listing the runs of $what failed"
  [[ -z $run ]] || break
  ((SECONDS - start < appear)) || die "no run of $what appeared within ${appear}s"
  sleep "$interval"
done

IFS=$'\t' read -r id status url conclusion <<<"$run"
log "$what: run $url"
start=$SECONDS
last_status=""
while [[ $status != completed ]]; do
  if [[ $status != "$last_status" ]]; then
    log "$what: $status"
    last_status=$status
  fi
  ((SECONDS - start < timeout)) || die "$what did not complete within ${timeout}s: $url"
  sleep "$interval"
  run=$(gh api "repos/$repo/actions/runs/$id" --jq '[.status, (.conclusion // "none")] | @tsv') ||
    die "reading run $url failed"
  IFS=$'\t' read -r status conclusion <<<"$run"
done

if [[ $conclusion == success ]]; then
  log "$what: success"
  exit 0
fi
# The job and step summary helps to find the failing part.
gh run view "$id" -R "$repo" >&2 || true
die "$what concluded with $conclusion: $url"
