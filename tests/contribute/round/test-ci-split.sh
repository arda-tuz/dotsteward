# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The CI that `dotsteward contribute` waits for: pull requests and branch
# pushes of the repository run lint and the privacy scans only; the full
# check (`nix flake check`, the check job of ci.yml) runs for every push to
# main, nightly, on a manual dispatch and for pull requests from forks. Every
# run on main has a concurrency group of its own, so no newer run cancels or
# replaces it; shellcheck in lint runs one process per CPU. The checks
# publish waits for (CONTRIBUTE_PUBLISH_CHECKS, WORKFLOW/JOB) and the
# workflows of main's CI (CONTRIBUTE_MAIN_WORKFLOWS) exist as jobs and
# workflow files that run on those events. The release workflow runs
# `tools/version.sh release` once ci passed on main (never for a pull
# request) and on a dispatch on main, whose major input is the only way to
# a major release.

ci=$DS_REPO_ROOT/.github/workflows/ci.yml
privacy=$DS_REPO_ROOT/.github/workflows/privacy.yml
remote=$DS_REPO_ROOT/cli/lib/contribute-remote.sh
[[ -f $ci && -f $privacy ]] || ds_fail "ci.yml or privacy.yml is missing"

# job_if FILE JOB: the if: expression of a job (one line, or a folded block).
job_if() {
  awk -v job="$2" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { current = $1; sub(/:$/, "", current); folded = 0; next }
    current == job && /^    if:/ {
      line = $0
      sub(/^    if:[[:space:]]*/, "", line)
      if (line ~ /^>-?$/ || line ~ /^\|-?$/) { folded = 1; next }
      print line
      done = 1
      exit
    }
    current == job && folded {
      if ($0 ~ /^      /) { line = $0; sub(/^[[:space:]]+/, "", line); text = text (text == "" ? "" : " ") line; next }
      print text
      done = 1
      exit
    }
    END { if (!done && folded && text != "") print text }' "$1"
}

# evaluate EXPRESSION EVENT REF [HEAD_REPO [KEY=VALUE...]]: the GitHub
# expression for an event of the repository example-org/dotsteward on REF
# (a pull request from HEAD_REPO, - for none), with the further contexts
# KEY=VALUE, as true or false.
evaluate() {
  python3 -I - "$@" <<'PY'
import re
import sys

expression, event, ref = sys.argv[1:4]
head = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "-" else None
context = {
    "github.event_name": event,
    "github.ref": ref,
    "github.repository": "example-org/dotsteward",
    "github.event.pull_request.head.repo.full_name": head if event == "pull_request" else None,
}
for pair in sys.argv[5:]:
    key, _, value = pair.partition("=")
    context[key] = value
expression = expression.strip()
if expression.startswith("${{") and expression.endswith("}}"):
    expression = expression[3:-2]


def name(match):
    key = match.group(0)
    if key not in context:
        sys.exit(f"unknown context {key}")
    return repr(context[key])


python = re.sub(r"\bgithub(\.[A-Za-z_]+)+", name, expression)
python = python.replace("||", " or ").replace("&&", " and ")
python = re.sub(r"!(?!=)", " not ", python)
print("true" if eval(python, {"__builtins__": {}}) else "false")
PY
}

# --- the full check -------------------------------------------------------------------------

condition=$(job_if "$ci" check)
[[ -n $condition ]] || ds_fail "the check job of ci.yml has no if: condition, so it runs on every pull request"
assert_eq true "$(evaluate "$condition" push refs/heads/main)" "full check on a push to main"
assert_eq true "$(evaluate "$condition" schedule refs/heads/main)" "full check nightly"
assert_eq true "$(evaluate "$condition" workflow_dispatch refs/heads/main)" "full check on a dispatch"
assert_eq true "$(evaluate "$condition" pull_request refs/pull/7/merge contributor/dotsteward)" \
  "full check on a pull request from a fork"
assert_eq false "$(evaluate "$condition" pull_request refs/pull/7/merge example-org/dotsteward)" \
  "full check on a pull request of the repository"
assert_eq false "$(evaluate "$condition" push refs/heads/fix/example)" "full check on a branch push"
assert_eq "" "$(job_if "$ci" lint)" "lint runs on every event"

# The events: pushes, pull requests, the nightly schedule and a dispatch.
for event in push pull_request schedule workflow_dispatch; do
  grep -qE "^  $event:" "$ci" || ds_fail "ci.yml does not run on $event"
done
grep -qE '^    - cron: ' "$ci" || ds_fail "ci.yml has no nightly cron"

# Every run on main has a group of its own: the group names the commit.
group=$(sed -n 's/^  group: //p' "$ci")
assert_contains "$group" "github.sha" "the concurrency group of a run on main"
assert_contains "$(sed -n 's/^  cancel-in-progress: //p' "$ci")" "github.ref != 'refs/heads/main'" \
  "runs on main are never cancelled"

# The lint job runs shellcheck once per CPU, following the sourced files.
shellcheck_step=$(awk '/name: shellcheck/ { found = 1 } found && /shellcheck -x/ { print; exit }' "$ci")
# shellcheck disable=SC2016 # the workflow's own command line, not expanded here
assert_contains "$shellcheck_step" 'xargs -0 -r -P "$(nproc)"' "parallel shellcheck"

# --- the checks publish and release wait for --------------------------------------------------

workflow_name() {
  sed -n 's/^name: //p' "$1"
}
has_job() {
  grep -qE "^  $2:[[:space:]]*$" "$1"
}
checks=$(sed -n 's/^CONTRIBUTE_PUBLISH_CHECKS=(\(.*\))$/\1/p' "$remote")
assert_eq "ci/lint privacy/generic" "$checks" "the checks publish waits for"
for check in $checks; do
  case ${check%%/*} in
    "$(workflow_name "$ci")") file=$ci ;;
    "$(workflow_name "$privacy")") file=$privacy ;;
    *) ds_fail "no workflow is named ${check%%/*}" ;;
  esac
  has_job "$file" "${check#*/}" || ds_fail "${file##*/} has no job ${check#*/}"
  assert_eq "" "$(job_if "$file" "${check#*/}" | grep -F pull_request || true)" \
    "${check#*/} is not limited by the pull request event"
done
assert_contains "$(job_if "$privacy" generic)" "github.event.deleted" "generic skips only branch deletions"

workflows=$(sed -n 's/^CONTRIBUTE_MAIN_WORKFLOWS=(\(.*\))$/\1/p' "$remote")
assert_eq "ci.yml privacy.yml" "$workflows" "the workflows of main's CI"
for workflow in $workflows; do
  file=$DS_REPO_ROOT/.github/workflows/$workflow
  [[ -f $file ]] || ds_fail "main's CI names $workflow, which does not exist"
  awk '/^on:/ { on = 1; next } on && /^[^ ]/ { exit } on && /^  push:/ { found = 1 } END { exit !found }' "$file" ||
    ds_fail "$workflow does not run on push"
done

# --- the release workflow ---------------------------------------------------------------------

release=$DS_REPO_ROOT/.github/workflows/release.yml
[[ -f $release ]] || ds_fail "release.yml is missing"
awk '/^  workflow_run:/ { run = 1 } run && /- ci$/ { ci = 1 } run && /- completed$/ { done = 1 }
  run && /- main$/ { main = 1 } END { exit !(ci && done && main) }' "$release" ||
  ds_fail "release.yml does not run when ci completed on main"
grep -qE '^  workflow_dispatch:' "$release" || ds_fail "release.yml has no dispatch"
awk '/^      major:/ { major = 1 } major && /type: boolean/ { boolean = 1 } major && /default: false/ { off = 1 }
  END { exit !(boolean && off) }' "$release" || ds_fail "release.yml has no major input that is off by default"
grep -qE '^  contents: write$' "$release" || ds_fail "release.yml cannot write the tag and the release"
grep -qE '^  actions: write$' "$release" || ds_fail "release.yml cannot dispatch channels.yml"
# shellcheck disable=SC2016 # the workflow's own command lines, not expanded here
grep -qF 'bash tools/version.sh release "${args[@]}"' "$release" || ds_fail "release.yml does not run tools/version.sh release"
# shellcheck disable=SC2016 # as above
grep -qF '[[ $MAJOR != true ]] || args+=(--major)' "$release" || ds_fail "release.yml does not pass --major from its input only"

condition=$(job_if "$release" release)
run() {
  evaluate "$condition" workflow_run refs/heads/main - "github.event.workflow_run.conclusion=$1" \
    "github.event.workflow_run.event=$2" "github.event.workflow_run.head_repository.full_name=$3"
}
assert_eq true "$(run success push example-org/dotsteward)" "release after ci passed on a push to main"
assert_eq true "$(run success schedule example-org/dotsteward)" "release after the nightly ci passed"
assert_eq false "$(run failure push example-org/dotsteward)" "release after ci failed"
assert_eq false "$(run success pull_request contributor/dotsteward)" "release after a pull request's ci"
assert_eq false "$(run success push contributor/dotsteward)" "release after ci of another repository"
assert_eq true "$(evaluate "$condition" workflow_dispatch refs/heads/main - github.event.workflow_run.conclusion= \
  github.event.workflow_run.event= github.event.workflow_run.head_repository.full_name=)" "release on a dispatch on main"
assert_eq false "$(evaluate "$condition" workflow_dispatch refs/heads/fix/example - github.event.workflow_run.conclusion= \
  github.event.workflow_run.event= github.event.workflow_run.head_repository.full_name=)" "release on a dispatch elsewhere"
