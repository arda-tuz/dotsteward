#!/usr/bin/env bash
# Privacy drill on GitHub Actions: six deliberate leaks must turn the privacy
# workflow red, each one reported, none of them printed.
#
# Usage: tests/ci/privacy-drill.sh [--base-ref REF]
#
# Steps:
#   1. pick an entry of the private denylist ~/.config/dotsteward/denylist.txt
#      that a scan reports as exactly that entry (a plain word);
#   2. clone REF (default main) of the remote origin into a temporary
#      directory and stack the six leak commits of
#      tests/privacy/make-leak-commits.sh on it, with that entry as the
#      denylist leak;
#   3. scan them locally exactly like CI does and require the expected
#      findings before anything is pushed;
#   4. push them with --no-verify to a new branch leak-test/<UTC time> of
#      origin; the push run of privacy.yml must fail in its generic job with
#      the five generic findings (the denylist job is skipped off main);
#   5. dispatch privacy.yml on that branch with input ref=<that branch>; the
#      run must fail in both jobs, the denylist job with all six findings;
#   6. read every job log and require exactly the expected redacted findings
#      and no trace of the denylist entry;
#   7. delete the leak branch (also when a step fails).
#
# A dispatch runs the workflow file of the ref it is dispatched on, so REF
# must contain privacy.yml; the leak branch carries it. Both red runs belong
# to the leak branch only, never to REF, so a later wait for the runs of REF
# (tests/ci/wait-workflow.sh) still finds its green push run. Needs bash, git,
# an authenticated gh with workflow access, and the scanner of this checkout.
# Environment (seconds): DS_DRILL_TIMEOUT per run (default 3600),
# DS_DRILL_INTERVAL polling interval (default 10). Exit 0 when the drill
# passed and the branch is gone, 1 otherwise.
set -Eeuo pipefail

die() {
  printf '[dotsteward] ERROR: privacy-drill: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] privacy-drill: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

base_ref=main
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --base-ref)
      (($# >= 2)) && [[ -n $2 ]] || die "--base-ref requires a branch"
      base_ref=$2
      shift 2
      ;;
    *) die "usage: privacy-drill.sh [--base-ref REF]" ;;
  esac
done

seconds() {
  local value=${!1:-$2}
  [[ $value =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive number of seconds"
  printf '%s' "$value"
}
timeout=$(seconds DS_DRILL_TIMEOUT 3600)
interval=$(seconds DS_DRILL_INTERVAL 10)

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
scanner=$framework_root/cli/commands/scan.sh
generator=$framework_root/tests/privacy/make-leak-commits.sh
[[ -f $scanner && -f $generator ]] || die "the scanner or the leak generator is missing"
workflow=privacy.yml

denylist=$HOME/.config/dotsteward/denylist.txt
[[ -f $denylist && -r $denylist ]] || die "the private denylist ~/.config/dotsteward/denylist.txt is missing"

command -v gh >/dev/null 2>&1 || die "gh is required"
origin_url=$(git -C "$framework_root" remote get-url origin 2>/dev/null) || die "no remote named origin"
repo=$(gh repo view "$origin_url" --json nameWithOwner --jq .nameWithOwner) ||
  die "origin is not a GitHub repository gh can read"

work=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-drill.XXXXXX")
branch=leak-test/$(date -u +%Y%m%dT%H%M%SZ)
pushed=0

cleanup() {
  local status=$?
  if ((pushed)); then
    if git -C "$work/repo" push -q --no-verify "$origin_url" --delete "refs/heads/$branch"; then
      log "deleted $branch on origin"
    else
      printf '[dotsteward] ERROR: privacy-drill: could not delete %s on origin; delete it by hand\n' "$branch" >&2
      status=1
    fi
  fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# scan DIR ARG...: the scanner in DIR; prints its findings (stdout) and
# fails only on errors, never on findings.
scan() {
  local dir=$1 status=0
  shift
  (cd "$dir" && "$scanner" "$@" 2>"$work/scan.err") || status=$?
  if ((status > 1)) || { ((status == 1)) && ! grep -q '^\[dotsteward\] ERROR: scan found ' "$work/scan.err"; }; then
    cat "$work/scan.err" >&2
    die "the local scan failed"
  fi
}

# --- 1. denylist entry ---------------------------------------------------------

# The leak file content of tests/privacy/make-leak-commits.sh (leak 5).
leak5_content() {
  printf 'term drill %s\ndrill probe\n' "$1"
}

# Candidates: plain words (no prefix, comment, path, address or whitespace)
# that no public allowlist string contains, longest first, since a long
# entry is the least likely to occur by chance in a CI log.
allowlist=$framework_root/privacy/allowlist.txt
candidates=()
line_number=0
while IFS= read -r entry || [[ -n $entry ]]; do
  line_number=$((line_number + 1))
  entry=${entry%$'\r'}
  [[ $entry =~ ^[A-Za-z0-9][A-Za-z0-9._-]{3,}$ ]] || continue
  if [[ -f $allowlist ]] && grep -v '^#' "$allowlist" | grep -qiF -e "$entry"; then
    continue
  fi
  candidates+=("${#entry} $line_number $entry")
done <"$denylist"

term=""
term_line=0
probe=$work/probe
mkdir -p "$probe/privacy-drill"
while read -r _ line_number entry; do
  leak5_content "$entry" >"$probe/privacy-drill/leak-5.txt"
  found=$(scan "$probe" --tree --denylist "$denylist" --require-denylist --redact)
  if [[ $found == "denylist:$line_number privacy-drill/leak-5.txt:1" ]]; then
    term=$entry
    term_line=$line_number
    break
  fi
done < <(((${#candidates[@]})) && printf '%s\n' "${candidates[@]}" | sort -s -k1,1nr)
rm -rf -- "$probe"
[[ -n $term ]] || die "the denylist has no plain word that a scan reports as exactly that entry"
log "denylist leak uses denylist entry $term_line"

# --- 2. leak commits -------------------------------------------------------------

git clone -q --branch "$base_ref" "$origin_url" "$work/repo" ||
  die "cannot clone $base_ref of origin"
git -C "$work/repo" cat-file -e "HEAD:.github/workflows/$workflow" 2>/dev/null ||
  die "$base_ref has no .github/workflows/$workflow"
base=$(git -C "$work/repo" rev-parse HEAD)
generated=$(bash "$generator" "$work/repo" "$term") || die "the leak generator failed"
mapfile -t shas <<<"$generated"
((${#shas[@]} == 6)) || die "the leak generator did not print six commits"
for sha in "${shas[@]}"; do
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "the leak generator printed an unexpected line"
done
tip=${shas[5]}
[[ $(git -C "$work/repo" rev-parse HEAD) == "$tip" ]] || die "the leak commits are not at HEAD"

# --- 3. expected findings --------------------------------------------------------

s() {
  printf '%s' "${shas[$1]:0:12}"
}
generic_range="home-path commit $(s 0) privacy-drill/leak-1.txt:1
email commit $(s 1) privacy-drill/leak-2.txt:1
commit-timezone commit $(s 2) author-date
commit-line commit $(s 3) message:3
secret-private-key commit $(s 5) privacy-drill/leak-6.txt:1"
denylist_range="home-path commit $(s 0) privacy-drill/leak-1.txt:1
email commit $(s 1) privacy-drill/leak-2.txt:1
commit-timezone commit $(s 2) author-date
commit-line commit $(s 3) message:3
denylist:$term_line commit $(s 4) privacy-drill/leak-5.txt:1
secret-private-key commit $(s 5) privacy-drill/leak-6.txt:1"
generic_tree="home-path privacy-drill/leak-1.txt:1
email privacy-drill/leak-2.txt:1
secret-private-key privacy-drill/leak-6.txt:1"
denylist_tree="home-path privacy-drill/leak-1.txt:1
email privacy-drill/leak-2.txt:1
denylist:$term_line privacy-drill/leak-5.txt:1
secret-private-key privacy-drill/leak-6.txt:1"

# expect WHAT EXPECTED ACTUAL: compares finding lists (order-insensitive)
# and prints the redacted difference on mismatch.
expect() {
  local what=$1
  if [[ $(LC_ALL=C sort <<<"$2") != "$(LC_ALL=C sort <<<"$3")" ]]; then
    printf '%s: expected findings:\n%s\nactual findings:\n%s\n' "$what" "$2" "$3" >&2
    die "unexpected findings in $what"
  fi
}

found=$(scan "$work/repo" --range "$base..$tip" --metadata --redact)
expect "local scan of the pushed commits" "$generic_range" "$found"
found=$(scan "$work/repo" --range "$tip" --metadata --denylist "$denylist" --require-denylist --redact)
expect "local scan of the history with the denylist" "$denylist_range" "$found"
found=$(scan "$work/repo" --tree --redact)
expect "local scan of the tree" "$generic_tree" "$found"
found=$(scan "$work/repo" --tree --denylist "$denylist" --require-denylist --redact)
expect "local scan of the tree with the denylist" "$denylist_tree" "$found"
log "the local scans report the six leaks"

# --- 4. push run -------------------------------------------------------------------

# The REST API is used directly: unlike `gh run list --workflow`, it also
# finds runs of a workflow that does not exist on the default branch yet.

# newest_run EVENT BRANCH [COMMIT]: the id of the newest run of the
# workflow for the event and branch (and commit), or 0.
newest_run() {
  local args=(-f event="$1" -f branch="$2")
  [[ -z ${3:-} ]] || args+=(-f head_sha="$3")
  gh api -X GET "repos/$repo/actions/runs" "${args[@]}" -F per_page=100 \
    --jq "[.workflow_runs[] | select((.path | split(\"@\")[0]) == \".github/workflows/$workflow\") | .id]
      | max // 0"
}

# wait_run EVENT BRANCH AFTER [COMMIT]: waits for a run newer than the id
# AFTER and for its completion; prints its id.
wait_run() {
  local event=$1 ref=$2 after=$3 commit=${4:-} start=$SECONDS id status
  while :; do
    id=$(newest_run "$event" "$ref" "$commit") || die "listing the runs of $workflow failed"
    ((id <= after)) || break
    ((SECONDS - start < timeout)) || die "no $event run of $workflow on $ref appeared within ${timeout}s"
    sleep "$interval"
  done
  log "waiting for $event run $id"
  while :; do
    status=$(gh api "repos/$repo/actions/runs/$id" --jq .status) || die "reading run $id failed"
    [[ $status != completed ]] || break
    ((SECONDS - start < timeout)) || die "run $id did not complete within ${timeout}s"
    sleep "$interval"
  done
  printf '%s' "$id"
}

# check_run ID JOB=CONCLUSION...: the run failed and each named job has the
# given conclusion; prints the jobs as "name<TAB>id" lines.
check_run() {
  local id=$1 conclusion jobs pair name want got
  shift
  conclusion=$(gh api "repos/$repo/actions/runs/$id" --jq '.conclusion // "none"') ||
    die "reading run $id failed"
  [[ $conclusion == failure ]] || die "run $id concluded with $conclusion, not failure"
  jobs=$(gh api "repos/$repo/actions/runs/$id/jobs" \
    --jq '.jobs[] | [.name, .id, (.conclusion // "none")] | @tsv') ||
    die "reading the jobs of run $id failed"
  for pair in "$@"; do
    name=${pair%%=*}
    want=${pair#*=}
    got=$(awk -F '\t' -v name="$name" '$1 == name { print $3 }' <<<"$jobs")
    [[ $got == "$want" ]] || die "job $name of run $id concluded with ${got:-nothing}, not $want"
  done
  awk -F '\t' '{ print $1 "\t" $2 }' <<<"$jobs"
}

# job_findings JOB_ID: the redacted finding lines of a job log. Every log is
# also kept for the leak check at the end.
job_findings() {
  local id=$1 log_file=$work/job-$1.log attempt
  for attempt in 1 2 3 4 5 6; do
    # Job logs carry color escapes, which gh prints only on request.
    if gh api --allow-escape-sequences "repos/$repo/actions/jobs/$id/logs" >"$log_file" 2>/dev/null && [[ -s $log_file ]]; then
      break
    fi
    ((attempt < 6)) || die "the log of job $id is not available"
    sleep "$interval"
  done
  sed -E 's/\r$//; s/^\xEF\xBB\xBF//; s/\x1B\[[0-9;]*[A-Za-z]//g; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "$log_file" |
    grep -E '^(secret-[a-z-]+|home-path|email|private-ipv4|non-ascii|forbidden-path|commit-[a-z-]+|tag-[a-z-]+|denylist:[0-9]+|extra-term:[0-9]+) [^ ]' || true
}

job_id() {
  awk -F '\t' -v name="$2" '$1 == name { print $2 }' <<<"$1"
}

git -C "$work/repo" push -q --no-verify "$origin_url" "$tip:refs/heads/$branch" ||
  die "cannot push $branch to origin"
pushed=1
log "pushed the six leak commits to $branch"

push_run=$(wait_run push "$branch" 0 "$tip")
push_jobs=$(check_run "$push_run" generic=failure denylist=skipped)
found=$(job_findings "$(job_id "$push_jobs" generic)")
expect "the push run's generic job" "$generic_range
$generic_tree" "$found"
log "push run $push_run failed with the five generic findings"

# --- 5. dispatch run ----------------------------------------------------------------

# The branch is new, so any dispatch run of its tip is this one.
gh workflow run "$workflow" -R "$repo" --ref "$branch" -f ref="$branch" ||
  die "cannot dispatch $workflow on $branch"
dispatch_run=$(wait_run workflow_dispatch "$branch" 0 "$tip")
dispatch_jobs=$(check_run "$dispatch_run" generic=failure denylist=failure)
found=$(job_findings "$(job_id "$dispatch_jobs" generic)")
expect "the dispatch run's generic job" "$generic_range
$generic_tree" "$found"
found=$(job_findings "$(job_id "$dispatch_jobs" denylist)")
expect "the dispatch run's denylist job" "$denylist_range
$denylist_tree" "$found"
log "dispatch run $dispatch_run failed with all six findings"

# --- 6. nothing leaked into the logs -----------------------------------------------

if grep -qiF -e "$term" "$work"/job-*.log; then
  die "a CI log contains the denylist entry"
fi
log "drill passed: six leaks caught, no leaked text in the logs"
