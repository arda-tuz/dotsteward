# shellcheck shell=bash
# The remote steps of `dotsteward contribute` (SPEC 9.4 steps 7 to 11 and
# the recovery after a trial switch): trial, publish, release, upgrade,
# abort and report. Sourced by cli/commands/contribute.sh after
# cli/lib/contribute-local.sh, whose helpers and CT_* facts it uses;
# framework_root is the framework source of the running CLI.
#
#   contribute_cmd_trial, contribute_cmd_publish, contribute_cmd_release,
#   contribute_cmd_upgrade, contribute_cmd_abort, contribute_cmd_report
#                            the steps (arguments as in the command usage)
#   contribute_recover_run ID
#                            the recovery after a trial switch of run ID
#                            (nothing when the run never switched), for the
#                            red outcomes of `check`
#   contribute_flake_url_for_tag URL TAG [FORK]
#                            the dotsteward input URL URL moved to the
#                            release tag TAG (github:owner/repo[/ref] or a
#                            git+ URL with ?ref=refs/tags/TAG), on the
#                            GitHub repository FORK (owner/repo) when given
#
# The instance commands (gate, rebuild, e2e, update, sync) run with
# DOTSTEWARD_FRAMEWORK_OVERRIDE removed from their environment, so a
# framework override is exactly the --framework-override flag the trial
# passes (D9) and never leaks into the recovery or the upgrade. They run
# through the running CLI, except in the upgrade once flake.lock pins the
# release: from there on they run through the instance launcher
# (.dotsteward/cli.sh), so the release's CLI validates, rebuilds and
# publishes the upgraded instance and `static` compares the refreshed
# template files with the release's template/, not the running one's.
#
# Run state fields added by these steps (next to those of `start`):
#   profile          the profile of the trial (the current profile, else
#                    profiles.check), used again by the recovery and the
#                    upgrade
#   trial, trial_sha full or build-only, and the commit the trial passed for
#                    (publish needs trial_sha = test_sha)
#   upgrade          full or build-only
#   instance_base    the instance commit the upgrade started from (the
#                    remote branch at `update prepare`)
#   recovery         done or failed: the last recovery after a trial switch
#   outcome          completed (report) or aborted (abort)
#
# Environment (seconds, positive integers):
#   DOTSTEWARD_CONTRIBUTE_POLL_SECONDS    polling interval for CI (default 15)
#   DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS  how long CI may take to appear on a
#                                         pushed commit (default 300)
#   DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS
#                                         how long CI may take to finish
#                                         (default 7200)

# shellcheck disable=SC2154 # framework_root, CT_* and the CONTRIBUTE_* constants come from the dispatcher and contribute-local.sh

# The exit status of a run sent back to `check`: the branch was rebased onto
# the moved upstream main (or must be), so the tested commit is gone.
CONTRIBUTE_RESTART=5
# The workflow that exercises a change with a real activation (SPEC 11.6).
CONTRIBUTE_CLEAN_INSTALL=clean-install.yml

export GH_PROMPT_DISABLED=1

# --- run state ----------------------------------------------------------------------

# _contribute_get FIELD: one field of the current run (CT_RUN_ID), raw; empty
# for null or a missing field.
_contribute_get() {
  contribute_state_read "$CT_RUN_ID" | jq -r --arg field "$1" '.[$field] // "" | tostring'
}

# _contribute_set JQ_FILTER [JQ_OPTION...]: updates the current run.
_contribute_set() {
  contribute_state_update "$CT_RUN_ID" "$@"
}

# _contribute_load_run ID: CT_RUN_ID, CT_CLONE, CT_BRANCH, CT_RUN_MODE,
# CT_STEP, CT_TEST_SHA and CT_TESTED_TREE of run ID.
_contribute_load_run() {
  CT_RUN_ID=$1
  contribute_state_read "$CT_RUN_ID" >/dev/null
  CT_CLONE=$(_contribute_get clone)
  CT_BRANCH=$(_contribute_get branch)
  CT_RUN_MODE=$(_contribute_get mode)
  CT_STEP=$(_contribute_get step)
  CT_TEST_SHA=$(_contribute_get test_sha)
  CT_TESTED_TREE=$(_contribute_get tested_tree)
  [[ -n $CT_CLONE && -n $CT_BRANCH && ($CT_RUN_MODE == owner || $CT_RUN_MODE == fork) && -n $CT_STEP ]] ||
    die "the state file of run $CT_RUN_ID lacks its clone, branch, mode or step"
}

# _contribute_next_command STEP: the command that continues a run at STEP.
_contribute_next_command() {
  case $1 in
    reproduce) printf 'dotsteward contribute check --expect-fail <test path>\n' ;;
    fix) printf 'dotsteward contribute check\n' ;;
    upgrade) printf 'dotsteward contribute upgrade --tag %s\n' "$(_contribute_get tag)" ;;
    done) printf 'nothing (the run is finished)\n' ;;
    *) printf 'dotsteward contribute %s\n' "$1" ;;
  esac
}

# _contribute_require_tested: the clone is clean on the run's branch at the
# commit the framework gate passed for.
_contribute_require_tested() {
  local current head
  contribute_is_clone "$CT_CLONE" || die "the clone $CT_CLONE of run $CT_RUN_ID is missing"
  current=$(git -C "$CT_CLONE" symbolic-ref --quiet --short HEAD 2>/dev/null) || current="a detached HEAD"
  [[ $current == "$CT_BRANCH" ]] || die "the clone is on $current, not on the run's branch $CT_BRANCH"
  contribute_require_clean "$CT_CLONE"
  head=$(git -C "$CT_CLONE" rev-parse HEAD)
  [[ $head == "$CT_TEST_SHA" ]] ||
    die "$CT_BRANCH moved after the framework gate (HEAD ${head:0:12}, checked ${CT_TEST_SHA:0:12}); run: dotsteward contribute check"
}

# _contribute_seconds NAME DEFAULT: a positive integer from the environment.
_contribute_seconds() {
  local value=${!1:-$2}
  [[ $value =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive number of seconds"
  printf '%s\n' "$value"
}

# --- instance -----------------------------------------------------------------------

# _contribute_instance COMMAND [ARG...]: dotsteward COMMAND ARG... on the
# instance, without an inherited framework override.
_contribute_instance() {
  log "dotsteward $*"
  env -u DOTSTEWARD_FRAMEWORK_OVERRIDE "$framework_root/cli/dotsteward" --instance "$DS_INSTANCE_ROOT" "$@"
}

# _contribute_pinned COMMAND [ARG...]: dotsteward COMMAND ARG... on the
# instance through its launcher, so with the CLI pinned by its flake.lock
# (built once per lock; a dirty tracked tree is fine), without an inherited
# framework override.
_contribute_pinned() {
  [[ -x $DS_INSTANCE_ROOT/.dotsteward/cli.sh ]] ||
    _contribute_red "the instance has no executable launcher .dotsteward/cli.sh, so it cannot run the CLI pinned by flake.lock"
  log "dotsteward $* (the CLI pinned by flake.lock)"
  env -u DOTSTEWARD_FRAMEWORK_OVERRIDE "$DS_INSTANCE_ROOT/.dotsteward/cli.sh" "$@"
}

# _contribute_profile: the profile of the run, else the current profile
# (<state>/current/profile, written by rebuild), else profiles.check.
_contribute_profile() {
  local profile file
  profile=$(_contribute_get profile)
  if [[ -z $profile ]]; then
    file=$(state_root)/current/profile
    if [[ -f $file ]]; then
      profile=$(<"$file")
      profile=${profile%%[[:space:]]*}
    fi
  fi
  [[ -n $profile ]] || profile=$DS_PROFILES_CHECK
  require_profile "$profile"
  printf '%s\n' "$profile"
}

_contribute_instance_dirty() {
  [[ -n $(git -C "$DS_INSTANCE_ROOT" status --porcelain --untracked-files=normal 2>/dev/null) ]]
}

# --- recovery -----------------------------------------------------------------------

# _contribute_recover: after a trial switch, switches the live generation
# back to the instance's pinned framework (rebuild --switch and e2e without
# an override); nothing when the run never switched. A failed recovery is
# resumed: once its rebuild switched back (trial_switched false), only its
# e2e runs again. Status 1 when the recovery could not run or failed;
# recovery is done only once the e2e passed.
_contribute_recover() {
  local switched profile base commit
  local -a e2e=()
  switched=$(_contribute_get trial_switched)
  [[ $switched == true || $(_contribute_get recovery) == failed ]] || return 0
  profile=$(_contribute_profile) || return 1
  if [[ $switched == true ]]; then
    if _contribute_instance_dirty; then
      _contribute_set '.recovery = "failed"'
      printf '[dotsteward] ERROR: recovery not run: the instance %s has uncommitted changes, so it cannot be rebuilt; the live generation still uses the trial framework. Finish them (dotsteward contribute upgrade) or remove them, then run: dotsteward contribute abort\n' \
        "$DS_INSTANCE_ROOT" >&2
      return 1
    fi
    log "recovery: switching the live generation back to the instance's pinned framework"
    if ! _contribute_instance rebuild --profile "$profile" --switch; then
      _contribute_set '.recovery = "failed"'
      printf '[dotsteward] ERROR: recovery failed: rebuild --switch without the override failed, so the live generation may still use the trial framework; fix the problem, then run: dotsteward contribute abort\n' >&2
      return 1
    fi
    _contribute_set '.trial_switched = false'
  else
    log "recovery: the live generation uses the instance's pinned framework again; running its e2e, which failed last time"
  fi
  e2e=(e2e --profile "$profile")
  base=$(_contribute_get instance_base)
  commit=$(_contribute_get instance_commit)
  if [[ $(_contribute_get step) == upgrade && -n $base && -n $commit ]]; then
    e2e+=(--expected-remote-base "$base")
  fi
  if ! _contribute_instance "${e2e[@]}"; then
    _contribute_set '.recovery = "failed"'
    printf '[dotsteward] ERROR: recovery: the live generation uses the pinned framework again, but its e2e failed; see the findings above\n' >&2
    return 1
  fi
  _contribute_set '.recovery = "done"'
  log "recovery done: the live generation and its framework skills use the instance's pinned framework again"
}

# contribute_recover_run ID: the recovery after a trial switch for run ID,
# for a red step outside this library (a privacy stop or a failed nix flake
# check of `check` on a run that publish sent back after its trial). Never
# fails: a failed recovery prints its error and is recorded in the run.
contribute_recover_run() {
  CT_RUN_ID=$1
  _contribute_recover || true
}

# _contribute_red MESSAGE: a red step: the message, the recovery after a
# trial switch, exit 1.
_contribute_red() {
  printf '[dotsteward] ERROR: %s\n' "$1" >&2
  _contribute_recover || true
  exit 1
}

# --- trial --------------------------------------------------------------------------

contribute_cmd_trial() {
  local id="" build_only=0
  while (($#)); do
    case $1 in
      --build-only) build_only=1 ;;
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  case $CT_STEP in
    trial | publish) ;;
    reproduce | fix | check) die "run $id has not passed the framework gate; run: dotsteward contribute check" ;;
    *) die "run $id is past the trial; next: $(_contribute_next_command "$CT_STEP")" ;;
  esac
  [[ -n $CT_TEST_SHA && -n $CT_TESTED_TREE ]] ||
    die "run $id has not passed the framework gate; run: dotsteward contribute check"
  _contribute_require_tested
  [[ $CT_CLONE =~ ^/[A-Za-z0-9._/+@-]+$ ]] ||
    die "the clone path $CT_CLONE cannot be written into a flake reference; set upstream.local_clone to a path of letters, digits and ./_+@-"

  local profile ref kind=full
  ((build_only == 0)) || kind=build-only
  profile=$(_contribute_profile)
  ref="git+file://$CT_CLONE?rev=$CT_TEST_SHA"
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.profile = $profile | .trial = null | .trial_sha = null' --arg profile "$profile"
  log "trial ($kind) of ${CT_TEST_SHA:0:12} on profile $profile with --framework-override $ref"

  _contribute_instance gate --scope maintain --framework-override "$ref" ||
    _contribute_red "trial: the gate failed with the framework at ${CT_TEST_SHA:0:12}; nothing is published"
  if ((build_only)); then
    _contribute_instance rebuild --profile "$profile" --build-only --framework-override "$ref" ||
      _contribute_red "trial: rebuild --build-only failed with the framework at ${CT_TEST_SHA:0:12}; nothing is published"
  else
    # Set before the switch: a switch that fails half way needs the recovery.
    _contribute_set '.trial_switched = true'
    _contribute_instance rebuild --profile "$profile" --switch --framework-override "$ref" ||
      _contribute_red "trial: rebuild --switch failed with the framework at ${CT_TEST_SHA:0:12}; nothing is published"
    _contribute_instance e2e --profile "$profile" --framework-override "$ref" ||
      _contribute_red "trial: e2e failed with the framework at ${CT_TEST_SHA:0:12}; nothing is published"
  fi
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.trial = $kind | .trial_sha = $sha | .step = "publish"' --arg kind "$kind" --arg sha "$CT_TEST_SHA"
  if ((build_only)); then
    log "trial passed (build-only): ${CT_TEST_SHA:0:12} builds on this machine; publish also needs $CONTRIBUTE_CLEAN_INSTALL green on it"
  else
    log "trial passed: this machine runs the framework at ${CT_TEST_SHA:0:12}"
  fi
  log "next: dotsteward contribute publish"
}

# --- remote facts -------------------------------------------------------------------

# _contribute_remote_facts: the upstream facts (contribute-local.sh) for the
# run's mode, CT_PUBLISH_SLUG (the GitHub repository publish pushes to: the
# upstream in owner mode, the fork in fork mode) and verified clone remotes.
_contribute_remote_facts() {
  local origin
  _contribute_load_context
  _contribute_load_protocol
  _contribute_load_upstream
  # The CT_* facts below are read by contribute-local.sh as well.
  # shellcheck disable=SC2034
  CT_MODE=$CT_RUN_MODE
  CT_FORK_SLUG=""
  CT_FORK_URL=""
  if [[ $CT_MODE == owner ]]; then
    # shellcheck disable=SC2034 # read by contribute-local.sh
    CT_UPSTREAM_REMOTE=origin
    [[ -n $CT_UPSTREAM_SLUG ]] ||
      die "owner mode publishes through GitHub, but the upstream $CT_UPSTREAM is not a GitHub repository"
    CT_PUBLISH_SLUG=$CT_UPSTREAM_SLUG
  else
    # shellcheck disable=SC2034 # read by contribute-local.sh
    CT_UPSTREAM_REMOTE=upstream
    origin=$(_contribute_remote_url "$CT_CLONE" origin)
    CT_FORK_SLUG=$(_contribute_github_slug "$origin") ||
      die "the origin of $CT_CLONE is not a GitHub repository: ${origin:-unset}"
    # shellcheck disable=SC2034 # read by contribute-local.sh
    CT_FORK_URL=$origin
    CT_PUBLISH_SLUG=$CT_FORK_SLUG
  fi
  _contribute_verify_remotes 0
}

_contribute_require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh is not installed; publishing needs it"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in; run 'gh auth login' first"
}

# _contribute_remote_ref REMOTE REF: the commit REF has on REMOTE (peeled for
# an annotated tag), empty when it does not exist; status 1 when the remote
# cannot be read.
_contribute_remote_ref() {
  local remote=$1 ref=$2 answer line peeled="" plain=""
  answer=$(git_net 60 -C "$CT_CLONE" ls-remote "$remote" "$ref" "$ref^{}") || return 1
  while IFS=$'\t' read -r sha name; do
    [[ -n ${sha:-} ]] || continue
    if [[ $name == "$ref^{}" ]]; then
      peeled=$sha
    elif [[ $name == "$ref" ]]; then
      plain=$sha
    fi
  done <<<"$answer"
  line=${peeled:-$plain}
  printf '%s\n' "$line"
}

# --- publish: branch and upstream main --------------------------------------------

# _contribute_up_to_date REMOTE: REMOTE/main (fetched now) is an ancestor of
# the tested commit. Otherwise the branch is rebased onto it (a conflict is
# aborted and left to the user), the run goes back to check and the command
# exits with CONTRIBUTE_RESTART.
_contribute_up_to_date() {
  local remote=$1 main
  contribute_fetch_main "$CT_CLONE" "$remote"
  main=$(git -C "$CT_CLONE" rev-parse "refs/remotes/$remote/main^{commit}")
  if git -C "$CT_CLONE" merge-base --is-ancestor "$main" "$CT_TEST_SHA"; then
    return 0
  fi
  log "$remote/main moved to ${main:0:12}; rebasing $CT_BRANCH onto it"
  _contribute_set '.step = "check" | .test_sha = null | .tested_tree = null | .trial = null | .trial_sha = null'
  if ! (cd -- "$CT_CLONE" && TZ=UTC git rebase --quiet "refs/remotes/$remote/main") </dev/null >/dev/null 2>&1; then
    git -C "$CT_CLONE" rebase --abort >/dev/null 2>&1 || true
    printf '[dotsteward] ERROR: %s conflicts with %s/main: rebase it by hand in %s (with TZ=UTC), then run: dotsteward contribute check\n' \
      "$CT_BRANCH" "$remote" "$CT_CLONE" >&2
    exit "$CONTRIBUTE_RESTART"
  fi
  log "rebased $CT_BRANCH onto $remote/main (now $(git -C "$CT_CLONE" rev-parse --short=12 HEAD)); the tested commit changed"
  log "the run is back at the framework gate; next: dotsteward contribute check, then trial and publish again"
  exit "$CONTRIBUTE_RESTART"
}

# _contribute_push_branch REMOTE: the tested commit as the run's branch on
# REMOTE, replacing only what the remote had when it was read.
_contribute_push_branch() {
  local remote=$1 current
  current=$(_contribute_remote_ref "$remote" "refs/heads/$CT_BRANCH") ||
    _contribute_red "cannot read $CT_BRANCH on $remote"
  if [[ $current == "$CT_TEST_SHA" ]]; then
    log "$CT_BRANCH is already ${CT_TEST_SHA:0:12} on $remote"
    return 0
  fi
  git_net 180 -C "$CT_CLONE" push --quiet --force-with-lease="refs/heads/$CT_BRANCH:$current" \
    "$remote" "$CT_TEST_SHA:refs/heads/$CT_BRANCH" </dev/null ||
    _contribute_red "pushing $CT_BRANCH to $remote failed; nothing is published"
  log "pushed $CT_BRANCH (${CT_TEST_SHA:0:12}) to $remote"
}

# _contribute_rebase_onto_merged REMOTE: after a pull request merged on
# GitHub (by hand, as a new squash or merge commit) whose commit is not the
# tested tree (SPEC 9.4 step 8: rebase, back to step 6). The
# branch is rebased onto REMOTE/main (fetched): its commits are in the
# merge commit, so it becomes REMOTE/main; a conflicting rebase is aborted
# and the branch reset to REMOTE/main, which already holds the change. The
# merged pull request stays recorded (publish then takes the re-checked
# commit on REMOTE/main as published), unless the branch keeps commits that
# REMOTE/main lacks: those need a new pull request. No recovery: the run
# continues at check; exits with CONTRIBUTE_RESTART.
_contribute_rebase_onto_merged() {
  local remote=$1 main
  main=$(git -C "$CT_CLONE" rev-parse "refs/remotes/$remote/main^{commit}")
  _contribute_set '.step = "check" | .test_sha = null | .tested_tree = null | .trial = null | .trial_sha = null'
  log "rebasing $CT_BRANCH onto $remote/main (${main:0:12}), which holds the merged pull request"
  if ! (cd -- "$CT_CLONE" && TZ=UTC git rebase --quiet "refs/remotes/$remote/main") </dev/null >/dev/null 2>&1; then
    git -C "$CT_CLONE" rebase --abort >/dev/null 2>&1 || true
    log "$CT_BRANCH conflicts with $remote/main, which already holds its change: resetting it to $remote/main"
    git -C "$CT_CLONE" reset --quiet --hard "refs/remotes/$remote/main" ||
      die "cannot reset $CT_BRANCH to $remote/main in $CT_CLONE; reset it by hand, then run: dotsteward contribute check"
  fi
  if git -C "$CT_CLONE" merge-base --is-ancestor HEAD "refs/remotes/$remote/main"; then
    log "$CT_BRANCH is now $remote/main ($(git -C "$CT_CLONE" rev-parse --short=12 HEAD)); the tested commit changed"
  else
    _contribute_set '.pr = null'
    log "$CT_BRANCH keeps commits that $remote/main lacks (now $(git -C "$CT_CLONE" rev-parse --short=12 HEAD)); publish opens a new pull request for them"
  fi
  log "the run is back at the framework gate; next: dotsteward contribute check, then trial and publish again"
  exit "$CONTRIBUTE_RESTART"
}

# _contribute_verify_tree COMMIT REMOTE: COMMIT is on REMOTE/main (fetched
# now) and has the tested tree. A tree mismatch in owner mode (the pull
# request was merged on GitHub with other changes) releases nothing and
# sends the run back to check on the merged main.
_contribute_verify_tree() {
  local commit=$1 remote=$2 tree
  contribute_fetch_main "$CT_CLONE" "$remote"
  if ! git -C "$CT_CLONE" cat-file -e "$commit^{commit}" 2>/dev/null ||
    ! git -C "$CT_CLONE" merge-base --is-ancestor "$commit" "refs/remotes/$remote/main"; then
    _contribute_red "the published commit ${commit:0:12} is not on $remote/main"
  fi
  tree=$(git -C "$CT_CLONE" rev-parse "$commit^{tree}")
  if [[ $tree != "$CT_TESTED_TREE" ]]; then
    # shellcheck disable=SC2016 # jq variables
    _contribute_set '.merged_sha = $commit' --arg commit "$commit"
    [[ $CT_RUN_MODE == owner ]] ||
      _contribute_red "tree mismatch: the published commit ${commit:0:12} has tree ${tree:0:12}, but the tested tree is ${CT_TESTED_TREE:0:12}; nothing is released"
    printf '[dotsteward] ERROR: tree mismatch: the published commit %s has tree %s, but the tested tree is %s (the pull request was merged on GitHub with other changes); nothing is released\n' \
      "${commit:0:12}" "${tree:0:12}" "${CT_TESTED_TREE:0:12}" >&2
    _contribute_rebase_onto_merged "$remote"
  fi
  log "verified: ${commit:0:12} on $remote/main has the tested tree ${CT_TESTED_TREE:0:12}"
}

# _contribute_require_version COMMIT: VERSION at COMMIT equals the release
# this run will tag (the recorded tag, else the next patch tag), checked
# before main is touched; red otherwise.
_contribute_require_version() {
  local commit=$1 tag version
  tag=$(_contribute_get tag)
  [[ -n $tag ]] || tag=$(_contribute_next_tag)
  version=$(git -C "$CT_CLONE" show "$commit:VERSION" 2>/dev/null) ||
    _contribute_red "${commit:0:12} has no VERSION file; nothing is published"
  version=${version//[[:space:]]/}
  [[ v$version == "$tag" ]] ||
    _contribute_red "VERSION is $version at ${commit:0:12}, but the next release is $tag: set VERSION to ${tag#v} in the fix, then run: dotsteward contribute check; nothing is published"
}

# --- publish: CI ----------------------------------------------------------------------

# _contribute_runs REPO SHA WORKFLOW EVENT: the workflow runs of commit SHA
# in REPO, newest first, as "id status conclusion url" lines; WORKFLOW (a
# file name) and EVENT narrow them when not empty. The REST API also finds
# runs of a workflow that is not on the default branch yet.
_contribute_runs() {
  local repo=$1 sha=$2 workflow=$3 event=$4 answer
  answer=$(gh api -X GET "repos/$repo/actions/runs" -f head_sha="$sha" -F per_page=100 </dev/null) || return 1
  jq -r --arg workflow "$workflow" --arg event "$event" '
    [.workflow_runs[]?
      | select($workflow == "" or ((.path // "") | split("@")[0]) == ".github/workflows/" + $workflow)
      | select($event == "" or .event == $event)]
    | sort_by(.created_at, .id) | reverse | .[]
    | "\(.id) \(.status) \(.conclusion // "none") \(.html_url // "")"' <<<"$answer"
}

# _contribute_wait_run REPO ID WHAT: waits for run ID to complete; red unless
# it concluded with success (or was skipped).
_contribute_wait_run() {
  local repo=$1 run=$2 what=$3 interval timeout start answer status conclusion url
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  timeout=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS 7200)
  start=$SECONDS
  while :; do
    answer=$(gh api "repos/$repo/actions/runs/$run" </dev/null) || _contribute_red "cannot read run $run of $what in $repo"
    read -r status conclusion url < <(jq -r '"\(.status) \(.conclusion // "none") \(.html_url // "")"' <<<"$answer")
    [[ $status != completed ]] || break
    ((SECONDS - start < timeout)) || _contribute_red "$what did not finish within ${timeout}s: $url"
    sleep "$interval"
  done
  case $conclusion in
    success | skipped | neutral) log "$what: $conclusion ($url)" ;;
    *) _contribute_red "$what concluded with $conclusion: $url; nothing is published" ;;
  esac
}

# _contribute_wait_pr_checks PR: the checks of the pull request appear and
# all pass (gh pr checks --watch).
_contribute_wait_pr_checks() {
  local pr=$1 interval appear timeout start count
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  appear=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS 300)
  timeout=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS 7200)
  start=$SECONDS
  while :; do
    count=$(gh pr checks "$pr" --json name --jq length </dev/null 2>/dev/null) || count=0
    [[ $count =~ ^[0-9]+$ ]] || count=0
    ((count == 0)) || break
    ((SECONDS - start < appear)) ||
      _contribute_red "no CI check appeared on $pr within ${appear}s; publishing needs green CI, main is untouched"
    sleep "$interval"
  done
  log "waiting for the CI checks of $pr"
  timeout "$timeout" gh pr checks "$pr" --watch --fail-fast --interval "$interval" </dev/null ||
    _contribute_red "CI is not green on $pr; main is untouched"
  log "CI is green on $pr"
}

# _contribute_clean_install REPO: the clean-install workflow concluded with
# success on the tested commit, dispatched on the run's branch when it has
# no run there yet (or only a failed one).
_contribute_clean_install() {
  local repo=$1 what="$CONTRIBUTE_CLEAN_INSTALL on ${CT_TEST_SHA:0:12}" runs newest="" run status conclusion
  local interval appear start before=""
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  appear=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS 300)
  runs=$(_contribute_runs "$repo" "$CT_TEST_SHA" "$CONTRIBUTE_CLEAN_INSTALL" "") ||
    _contribute_red "cannot list the runs of $what in $repo"
  newest=$(head -n 1 <<<"$runs")
  if [[ -n $newest ]]; then
    read -r run status conclusion _ <<<"$newest"
    if [[ $status == completed && $conclusion == success ]]; then
      log "$what: success"
      return 0
    fi
    [[ $status == completed ]] || {
      _contribute_wait_run "$repo" "$run" "$what"
      return 0
    }
    before=$run
  fi
  log "the build-only trial needs $what green: dispatching it on $CT_BRANCH in $repo"
  gh workflow run "$CONTRIBUTE_CLEAN_INSTALL" -R "$repo" --ref "$CT_BRANCH" </dev/null ||
    _contribute_red "cannot dispatch $CONTRIBUTE_CLEAN_INSTALL in $repo"
  start=$SECONDS
  while :; do
    runs=$(_contribute_runs "$repo" "$CT_TEST_SHA" "$CONTRIBUTE_CLEAN_INSTALL" "") ||
      _contribute_red "cannot list the runs of $what in $repo"
    newest=$(head -n 1 <<<"$runs")
    run=${newest%% *}
    [[ -z $newest || $run == "$before" ]] || break
    ((SECONDS - start < appear)) || _contribute_red "no run of $what appeared within ${appear}s"
    sleep "$interval"
  done
  _contribute_wait_run "$repo" "$run" "$what"
}

# _contribute_fork_ci: the push runs of the tested commit on the fork all
# pass; skipped with a warning when GitHub Actions are disabled there.
_contribute_fork_ci() {
  local repo=$CT_PUBLISH_SLUG enabled runs line run interval appear start
  enabled=$(gh api "repos/$repo/actions/permissions" </dev/null 2>/dev/null | jq -r '.enabled') || enabled=""
  if [[ $enabled == false ]]; then
    warn "GitHub Actions are disabled on $repo, so no CI runs there; relying on the framework gate and the trial"
    return 0
  fi
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  appear=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS 300)
  start=$SECONDS
  while :; do
    runs=$(_contribute_runs "$repo" "$CT_TEST_SHA" "" push) || _contribute_red "cannot list the CI runs in $repo"
    [[ -z $runs ]] || break
    ((SECONDS - start < appear)) ||
      _contribute_red "no CI run appeared in $repo for ${CT_TEST_SHA:0:12} within ${appear}s; nothing is published"
    sleep "$interval"
  done
  while read -r line; do
    run=${line%% *}
    _contribute_wait_run "$repo" "$run" "CI run $run on ${CT_TEST_SHA:0:12}"
  done <<<"$runs"
}

# --- publish: pull requests -----------------------------------------------------------

# _contribute_pr_text: the title (first line) and body of a pull request
# for the run's commits.
_contribute_pr_title() {
  git -C "$CT_CLONE" log -1 --format=%s "$CT_TEST_SHA"
}

_contribute_pr_body() {
  local base=$1
  printf 'Commits:\n\n'
  git -C "$CT_CLONE" log --reverse --format='- %s' "$base..$CT_TEST_SHA"
  # shellcheck disable=SC2016 # the backquotes are Markdown
  printf '\nValidated with `dotsteward contribute`: the framework gate (nix flake check and the privacy scans) and a %s trial on an instance, at %s.\n' \
    "$(_contribute_get trial)" "${CT_TEST_SHA:0:12}"
}

# _contribute_find_pr REPO HEAD_OWNER: prints the URL of the open pull
# request of the run's branch in REPO whose head belongs to HEAD_OWNER
# (nothing when there is none); status 1 when gh cannot list them.
_contribute_find_pr() {
  local repo=$1 owner=$2 answer
  answer=$(gh pr list -R "$repo" --head "$CT_BRANCH" --state open --json url,headRepositoryOwner </dev/null) ||
    return 1
  jq -r --arg owner "$owner" \
    '[.[] | select((.headRepositoryOwner.login // "" | ascii_downcase) == ($owner | ascii_downcase))][0].url // empty' \
    <<<"$answer"
}

# _contribute_open_pr REPO HEAD BASE_REMOTE: CT_PR, the found or created pull
# request of HEAD (branch or owner:branch) into main of REPO, recorded in the
# run.
_contribute_open_pr() {
  local repo=$1 head=$2 remote=$3 owner answer
  owner=${head%%:*}
  [[ $head == *:* ]] || owner=${repo%%/*}
  CT_PR=$(_contribute_find_pr "$repo" "$owner") || _contribute_red "cannot list the pull requests of $repo"
  if [[ -n $CT_PR ]]; then
    log "reusing $CT_PR"
  else
    answer=$(gh pr create -R "$repo" --base main --head "$head" --title "$(_contribute_pr_title)" \
      --body "$(_contribute_pr_body "refs/remotes/$remote/main")" </dev/null) ||
      _contribute_red "cannot open a pull request of $head in $repo"
    CT_PR=$(grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' <<<"$answer" | tail -n 1) || CT_PR=""
    [[ -n $CT_PR ]] || _contribute_red "gh pr create printed no pull request URL"
    log "opened $CT_PR"
  fi
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.pr = $pr' --arg pr "$CT_PR"
}

# --- publish ------------------------------------------------------------------------

# _contribute_fast_forward_main PR: main of origin fast-forwarded to the
# tested commit, the merge of PR. The checked commits land unchanged, with
# the framework identity and UTC dates; a merge made by GitHub would write a
# new commit authored with the account's display name and local time, which
# the privacy scans refuse. GitHub records PR as merged once its head is on
# main. A push that no longer fast-forwards (main moved since the last
# check) rebases the branch and goes back to check; any other refusal is
# red with main untouched.
_contribute_fast_forward_main() {
  local pr=$1 main
  main=$(_contribute_remote_ref origin refs/heads/main) || _contribute_red "cannot read main of $CT_PUBLISH_SLUG"
  if [[ $main == "$CT_TEST_SHA" ]]; then
    log "main of $CT_PUBLISH_SLUG is already ${CT_TEST_SHA:0:12}"
    return 0
  fi
  log "merging $pr: fast-forwarding main of $CT_PUBLISH_SLUG to ${CT_TEST_SHA:0:12}"
  if ! git_net 180 -C "$CT_CLONE" push --quiet origin "$CT_TEST_SHA:refs/heads/main" </dev/null; then
    _contribute_up_to_date origin
    _contribute_red "pushing ${CT_TEST_SHA:0:12} to main of $CT_PUBLISH_SLUG was refused; main is untouched"
  fi
}

# _contribute_publish_owner: the recorded pull request is read first, so a
# run interrupted after the merge (before merged_sha was recorded) resumes
# at the verification; the branch checks, the push and the pull request
# only run while it is not merged. A merged pull request whose tested
# commit is on origin/main was merged by this run, or is a run re-checked
# on the merged main after a tree mismatch: that commit is the published
# one. A pull request merged on GitHub by hand is verified through its
# merge commit. VERSION is checked before main is touched, and again right
# before the merge (a release tagged while CI ran moves the next tag).
_contribute_publish_owner() {
  local pr state answer merged=""
  pr=$(_contribute_get pr)
  state=OPEN
  if [[ -n $pr ]]; then
    answer=$(gh pr view "$pr" --json state </dev/null) || _contribute_red "cannot read $pr"
    state=$(jq -r '.state' <<<"$answer")
    [[ $state != CLOSED ]] || die "the pull request $pr is closed; reopen it, or end the run with: dotsteward contribute abort"
  fi
  if [[ $state != MERGED ]]; then
    _contribute_require_version "$CT_TEST_SHA"
    _contribute_up_to_date origin
    _contribute_push_branch origin
    if [[ -z $pr ]]; then
      _contribute_open_pr "$CT_PUBLISH_SLUG" "$CT_BRANCH" origin
      pr=$CT_PR
    fi
    _contribute_wait_pr_checks "$pr"
    [[ $(_contribute_get trial) != build-only ]] || _contribute_clean_install "$CT_PUBLISH_SLUG"
    _contribute_up_to_date origin
    _contribute_require_version "$CT_TEST_SHA"
    _contribute_fast_forward_main "$pr"
    merged=$CT_TEST_SHA
  else
    contribute_fetch_main "$CT_CLONE" origin
    if git -C "$CT_CLONE" merge-base --is-ancestor "$CT_TEST_SHA" refs/remotes/origin/main; then
      merged=$CT_TEST_SHA
      log "$pr is merged and ${CT_TEST_SHA:0:12} is on origin/main: it is the published commit"
    fi
  fi
  if [[ -z $merged ]]; then
    answer=$(gh pr view "$pr" --json state,mergeCommit </dev/null) || _contribute_red "cannot read $pr after the merge"
    merged=$(jq -r 'if .state == "MERGED" then .mergeCommit.oid // empty else empty end' <<<"$answer")
    [[ -n $merged ]] || _contribute_red "$pr is not merged"
  fi
  _contribute_verify_tree "$merged" origin
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.merged_sha = $merged | .step = "release"' --arg merged "$merged"
  log "published: $pr merged as ${merged:0:12}"
}

_contribute_publish_fork() {
  local to_upstream=$1 main pr build_only=0
  [[ $(_contribute_get trial) != build-only ]] || build_only=1
  if ((build_only)) &&
    [[ $(gh api "repos/$CT_PUBLISH_SLUG/actions/permissions" </dev/null 2>/dev/null | jq -r '.enabled') == false ]]; then
    die "the build-only trial needs $CONTRIBUTE_CLEAN_INSTALL green, but GitHub Actions are disabled on $CT_PUBLISH_SLUG; enable them there, or run a full trial"
  fi
  _contribute_require_version "$CT_TEST_SHA"
  _contribute_up_to_date upstream
  _contribute_push_branch origin
  _contribute_fork_ci
  ((build_only == 0)) || _contribute_clean_install "$CT_PUBLISH_SLUG"
  _contribute_up_to_date upstream
  _contribute_require_version "$CT_TEST_SHA"
  main=$(_contribute_remote_ref origin refs/heads/main) || _contribute_red "cannot read main of $CT_PUBLISH_SLUG"
  if [[ $main != "$CT_TEST_SHA" ]]; then
    git_net 180 -C "$CT_CLONE" push --quiet origin "$CT_TEST_SHA:refs/heads/main" </dev/null ||
      _contribute_red "main of $CT_PUBLISH_SLUG (${main:0:12}) cannot be fast-forwarded to ${CT_TEST_SHA:0:12}: it has commits that $CT_BRANCH lacks; merge them into the fork's main by hand"
    log "fast-forwarded main of $CT_PUBLISH_SLUG to ${CT_TEST_SHA:0:12}"
  fi
  _contribute_verify_tree "$CT_TEST_SHA" origin
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.merged_sha = $merged' --arg merged "$CT_TEST_SHA"
  if ((to_upstream)); then
    pr=$(_contribute_get pr)
    if [[ -z $pr ]]; then
      _contribute_open_pr "$CT_UPSTREAM_SLUG" "${CT_FORK_SLUG%%/*}:$CT_BRANCH" upstream
      pr=$CT_PR
    fi
    log "the upstream reviews $pr"
  fi
  _contribute_set '.step = "release"'
  log "published: main of $CT_PUBLISH_SLUG is ${CT_TEST_SHA:0:12}"
}

contribute_cmd_publish() {
  local id="" to_upstream=0
  while (($#)); do
    case $1 in
      --pr-to-upstream) to_upstream=1 ;;
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  case $CT_STEP in
    publish) ;;
    release | upgrade | report | done)
      log "run $id is already published: $(_contribute_get merged_sha)"
      return 0
      ;;
    *) die "run $id has not passed the trial; next: $(_contribute_next_command "$CT_STEP")" ;;
  esac
  [[ -n $CT_TEST_SHA && $(_contribute_get trial_sha) == "$CT_TEST_SHA" && -n $(_contribute_get trial) ]] ||
    die "the trial has not passed for ${CT_TEST_SHA:-the current commit}; run: dotsteward contribute trial"
  _contribute_require_tested
  _contribute_require_gh
  _contribute_remote_facts
  [[ $CT_RUN_MODE == fork ]] || ((to_upstream == 0)) || die "--pr-to-upstream is for fork mode"
  [[ $DS_UPSTREAM_PR_TO_UPSTREAM != true ]] || to_upstream=1
  if [[ $CT_RUN_MODE == owner ]]; then
    _contribute_publish_owner
  else
    _contribute_publish_fork "$to_upstream"
  fi
  log "next: dotsteward contribute release"
}

# --- release ------------------------------------------------------------------------

# _contribute_next_tag: v<X.Y.Z+1> from the newest stable v* tag of origin
# (and, in fork mode, of the upstream); v0.0.1 when there is none.
_contribute_next_tag() {
  local remote answer newest name
  local -a versions=()
  local -a remotes=(origin)
  [[ $CT_RUN_MODE != fork ]] || remotes+=(upstream)
  for remote in "${remotes[@]}"; do
    answer=$(git_net 60 -C "$CT_CLONE" ls-remote --tags --refs "$remote" 'refs/tags/v*') ||
      die "cannot list the tags of $remote"
    while read -r _ name; do
      name=${name#refs/tags/v}
      if [[ $name =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        versions+=("$name")
      fi
    done <<<"$answer"
  done
  if ((${#versions[@]} == 0)); then
    printf 'v0.0.1\n'
    return 0
  fi
  newest=$(printf '%s\n' "${versions[@]}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  printf 'v%s.%s.%s\n' "${newest%%.*}" "$(cut -d. -f2 <<<"$newest")" "$((${newest##*.} + 1))"
}

contribute_cmd_release() {
  local id=""
  while (($#)); do
    case $1 in
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  case $CT_STEP in
    release) ;;
    upgrade | report | done)
      log "run $id is already released: $(_contribute_get tag)"
      return 0
      ;;
    *) die "run $id is not published yet; next: $(_contribute_next_command "$CT_STEP")" ;;
  esac
  local merged tag version local_tag remote_tag
  merged=$(_contribute_get merged_sha)
  [[ -n $merged ]] || die "run $id has no merged commit; run: dotsteward contribute publish"
  contribute_is_clone "$CT_CLONE" || die "the clone $CT_CLONE of run $id is missing"
  [[ $CT_RUN_MODE != owner ]] || _contribute_require_gh
  _contribute_remote_facts
  git -C "$CT_CLONE" cat-file -e "$merged^{commit}" 2>/dev/null || contribute_fetch_main "$CT_CLONE" origin
  git -C "$CT_CLONE" cat-file -e "$merged^{commit}" 2>/dev/null || die "the merged commit ${merged:0:12} is not in $CT_CLONE"

  tag=$(_contribute_get tag)
  [[ -n $tag ]] || tag=$(_contribute_next_tag)
  version=$(git -C "$CT_CLONE" show "$merged:VERSION" 2>/dev/null) ||
    die "the merged commit ${merged:0:12} has no VERSION file"
  version=${version//[[:space:]]/}
  [[ v$version == "$tag" ]] ||
    _contribute_red "VERSION is $version at the merged commit ${merged:0:12}, but the next release is $tag: the fix must set VERSION to ${tag#v} (VERSION equals the released tag); nothing is released"
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.tag = $tag' --arg tag "$tag"

  local_tag=$(git -C "$CT_CLONE" rev-parse --verify --quiet "refs/tags/$tag^{commit}") || local_tag=""
  remote_tag=$(_contribute_remote_ref origin "refs/tags/$tag") || _contribute_red "cannot read the tags of origin"
  [[ -z $remote_tag || $remote_tag == "$merged" ]] ||
    _contribute_red "the tag $tag already exists on origin at ${remote_tag:0:12}, not at the merged commit ${merged:0:12}"
  if [[ -z $local_tag ]]; then
    if [[ -n $remote_tag ]]; then
      git_net 60 -C "$CT_CLONE" fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" </dev/null ||
        _contribute_red "cannot fetch the tag $tag"
    else
      TZ=UTC git -C "$CT_CLONE" tag -a "$tag" -m "dotsteward $tag" "$merged" ||
        _contribute_red "cannot create the tag $tag"
    fi
  elif [[ $local_tag != "$merged" ]]; then
    _contribute_red "the local tag $tag points at ${local_tag:0:12}, not at the merged commit ${merged:0:12}; delete it in $CT_CLONE"
  fi
  if [[ -z $remote_tag ]]; then
    git_net 180 -C "$CT_CLONE" push --quiet origin "refs/tags/$tag:refs/tags/$tag" </dev/null ||
      _contribute_red "pushing the tag $tag to origin failed"
    log "tagged ${merged:0:12} as $tag on $CT_PUBLISH_SLUG"
  fi
  if [[ $CT_RUN_MODE == owner ]]; then
    if gh release view "$tag" -R "$CT_PUBLISH_SLUG" --json tagName </dev/null >/dev/null 2>&1; then
      log "the release $tag exists"
    else
      gh release create "$tag" -R "$CT_PUBLISH_SLUG" --title "$tag" --generate-notes --verify-tag </dev/null >/dev/null ||
        _contribute_red "gh release create $tag failed"
      log "released $tag: https://github.com/$CT_PUBLISH_SLUG/releases/tag/$tag"
    fi
  fi
  _contribute_set '.step = "upgrade"'
  log "next: dotsteward contribute upgrade --tag $tag"
}

# --- upgrade ------------------------------------------------------------------------

# _contribute_url_query_without_ref QUERY: QUERY (without ?) without its ref
# and rev parameters.
_contribute_url_query_without_ref() {
  local part out=""
  local -a parts=()
  IFS='&' read -r -a parts <<<"$1"
  for part in "${parts[@]}"; do
    case ${part%%=*} in
      ref | rev | "") ;;
      *) out+="&$part" ;;
    esac
  done
  printf '%s\n' "${out#&}"
}

contribute_flake_url_for_tag() {
  local url=$1 tag=$2 fork=${3:-} rest query="" path base host
  case $url in
    github:*)
      rest=${url#github:}
      if [[ $rest == *\?* ]]; then
        query=${rest#*\?}
        rest=${rest%%\?*}
      fi
      [[ $rest =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/.+)?$ ]] || return 1
      path=${BASH_REMATCH[1]}
      [[ -z $fork ]] || path=$fork
      query=$(_contribute_url_query_without_ref "$query")
      printf 'github:%s/%s%s\n' "$path" "$tag" "${query:+?$query}"
      ;;
    git+*://*)
      base=${url%%\?*}
      [[ $url != *\?* ]] || query=${url#*\?}
      if [[ -n $fork ]]; then
        [[ $base =~ ^(git\+[a-z]+://([^/@]*@)?([^/:]+)(:[0-9]+)?)/(.+)$ ]] || return 1
        host=${BASH_REMATCH[3],,}
        [[ $host == github.com ]] || return 1
        path=${BASH_REMATCH[5]}
        if [[ $path == *.git ]]; then
          base=${BASH_REMATCH[1]}/$fork.git
        else
          base=${BASH_REMATCH[1]}/$fork
        fi
      fi
      query=$(_contribute_url_query_without_ref "$query")
      # Always the full tag ref: Nix reads a git+ ref without refs/ as a
      # branch (refs/heads/<ref>), whatever the url had before.
      printf '%s?%sref=refs/tags/%s\n' "$base" "${query:+$query&}" "$tag"
      ;;
    *) return 1 ;;
  esac
}

# _contribute_flake_url_line FILE: "LINE<TAB>URL" of the dotsteward input's
# url in the flake: `dotsteward.url = "..."` (also inputs.dotsteward.url), a
# one-line `dotsteward = { url = "..."; ... }` or the first `url = "..."` of
# a `dotsteward = {` block. Status 1 unless exactly one is found.
_contribute_flake_url_line() {
  awk '
    function report(line, text) {
      if (match(text, /url[[:space:]]*=[[:space:]]*"[^"]*"/)) {
        value = substr(text, RSTART, RLENGTH)
        sub(/^url[[:space:]]*=[[:space:]]*"/, "", value)
        sub(/"$/, "", value)
        found++
        result = line "\t" value
      }
    }
    {
      text = $0
      sub(/#.*/, "", text)
    }
    block {
      if (text ~ /(^|[^A-Za-z0-9_.-])url[[:space:]]*=/) { report(NR, text); block = 0; next }
      if (text ~ /}/) block = 0
      next
    }
    text ~ /(^|[^A-Za-z0-9_-])dotsteward\.url[[:space:]]*=/ {
      sub(/.*dotsteward\./, "", text); report(NR, text); next
    }
    text ~ /(^|[^A-Za-z0-9_-])dotsteward[[:space:]]*=[[:space:]]*\{/ {
      sub(/.*dotsteward[[:space:]]*=[[:space:]]*\{/, "", text)
      if (text ~ /(^|[^A-Za-z0-9_.-])url[[:space:]]*=/) { report(NR, text); next }
      if (text !~ /}/) block = 1
    }
    END {
      if (found != 1) exit 1
      print result
    }' "$1"
}

# _contribute_set_framework_url TAG FORK: the dotsteward input of the
# instance flake.nix moved to TAG (on FORK when not empty).
_contribute_set_framework_url() {
  local tag=$1 fork=$2 flake=$DS_INSTANCE_ROOT/flake.nix found line url new tmp
  [[ -f $flake ]] || _contribute_red "the instance has no flake.nix"
  found=$(_contribute_flake_url_line "$flake") ||
    _contribute_red "cannot find the one url of the dotsteward input in $flake; set it to the tag $tag by hand and run upgrade again"
  line=${found%%$'\t'*}
  url=${found#*$'\t'}
  new=$(contribute_flake_url_for_tag "$url" "$tag" "$fork") ||
    _contribute_red "unsupported dotsteward input url in flake.nix: $url"
  if [[ $new == "$url" ]]; then
    log "flake.nix already uses $new"
    return 0
  fi
  tmp=$(mktemp "$DS_INSTANCE_ROOT/.flake.nix.XXXXXX")
  CT_OLD=$url CT_NEW=$new awk -v target="$line" '
    NR == target {
      old = ENVIRON["CT_OLD"]; new = ENVIRON["CT_NEW"]
      i = index($0, "\"" old "\"")
      if (i > 0) $0 = substr($0, 1, i) new substr($0, i + 1 + length(old))
    }
    { print }' "$flake" >"$tmp"
  # Rewritten in place, so the file keeps its mode.
  cat -- "$tmp" >"$flake"
  rm -f -- "$tmp"
  log "flake.nix: dotsteward $url -> $new"
}

# _contribute_verify_lock TAG COMMIT: the instance flake.lock locks the
# dotsteward input at COMMIT, from the reference TAG.
_contribute_verify_lock() {
  local tag=$1 commit=$2 answer ref rev
  answer=$(jq -r '
    .nodes[.root].inputs.dotsteward as $name
    | if ($name | type) != "string" then empty else .nodes[$name] end
    | "\(.original.ref // "")|\(.locked.rev // "")"' "$DS_INSTANCE_ROOT/flake.lock" 2>/dev/null) || answer=""
  ref=${answer%%|*}
  rev=${answer#*|}
  [[ ${ref#refs/tags/} == "$tag" && $rev == "$commit" ]] ||
    _contribute_red "flake.lock locks dotsteward ${ref:-without a ref} at ${rev:-no revision}, not $tag at ${commit:0:12}; the upgrade stops before any commit"
  log "flake.lock: dotsteward $tag at ${commit:0:12}"
}

# _contribute_refresh_template TAG: bootstrap.sh and .dotsteward/cli.sh of
# the instance from template/ of the release (the files `dotsteward static`
# keeps byte-identical to the pinned framework's).
_contribute_refresh_template() {
  local tag=$1 path mode target tmp
  for path in bootstrap.sh .dotsteward/cli.sh; do
    mode=$(git -C "$CT_CLONE" ls-tree "$tag" -- "template/$path" | awk '{print $1}')
    [[ -n $mode ]] || continue
    target=$DS_INSTANCE_ROOT/$path
    mkdir -p -- "$(dirname -- "$target")"
    tmp=$(mktemp "$(dirname -- "$target")/.refresh.XXXXXX")
    git -C "$CT_CLONE" show "$tag:template/$path" >"$tmp" || {
      rm -f -- "$tmp"
      _contribute_red "cannot read template/$path of $tag"
    }
    if [[ $mode == 100755 ]]; then chmod 0755 "$tmp"; else chmod 0644 "$tmp"; fi
    if [[ -f $target ]] && cmp -s -- "$tmp" "$target"; then
      rm -f -- "$tmp"
      continue
    fi
    mv -f -- "$tmp" "$target"
    log "refreshed $path from template/$path of $tag"
  done
}

contribute_cmd_upgrade() {
  local id="" tag_option="" build_only=0
  while (($#)); do
    case $1 in
      --tag)
        need_value "$1" "$#" "${2:-}"
        tag_option=$2
        shift
        ;;
      --build-only) build_only=1 ;;
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  case $CT_STEP in
    upgrade) ;;
    report | done)
      log "run $id already upgraded the instance: $(_contribute_get instance_commit)"
      return 0
      ;;
    *) die "run $id is not released yet; next: $(_contribute_next_command "$CT_STEP")" ;;
  esac
  local tag merged commit
  tag=$(_contribute_get tag)
  merged=$(_contribute_get merged_sha)
  [[ -n $tag && -n $merged ]] || die "run $id has no release tag; run: dotsteward contribute release"
  [[ -z $tag_option || $tag_option == "$tag" ]] || die "--tag $tag_option is not the release of run $id ($tag)"
  contribute_is_clone "$CT_CLONE" || die "the clone $CT_CLONE of run $id is missing"
  commit=$(git -C "$CT_CLONE" rev-parse --verify --quiet "refs/tags/$tag^{commit}") ||
    die "the tag $tag is missing in $CT_CLONE"
  [[ $commit == "$merged" ]] || die "the tag $tag points at ${commit:0:12}, not at the merged commit ${merged:0:12}"
  contribute_is_clone "$DS_INSTANCE_ROOT" || die "the instance $DS_INSTANCE_ROOT is not the top of a git clone"

  local profile fork="" base head instance_commit subject kind=full
  ((build_only == 0)) || kind=build-only
  profile=$(_contribute_profile)
  if [[ $CT_RUN_MODE == fork ]]; then
    _contribute_remote_facts
    fork=$CT_FORK_SLUG
  fi
  instance_commit=$(_contribute_get instance_commit)
  base=$(_contribute_get instance_base)
  if [[ -z $instance_commit ]]; then
    head=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
    if [[ -z $base ]]; then
      ! _contribute_instance_dirty ||
        die "the instance $DS_INSTANCE_ROOT has uncommitted changes; commit or remove them before the upgrade"
    else
      [[ $head == "$base" ]] ||
        die "the instance moved since the upgrade started (HEAD ${head:0:12}, started at ${base:0:12}); restore it or start the upgrade over"
    fi
    _contribute_instance update prepare --official-sources-only --scope maintain ||
      _contribute_red "upgrade: update prepare failed; the instance is unchanged"
    if [[ -z $base ]]; then
      base=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
      # shellcheck disable=SC2016 # jq variables
      _contribute_set '.instance_base = $base' --arg base "$base"
    fi
    _contribute_set_framework_url "$tag" "$fork"
    log "nix flake update dotsteward"
    nix_cmd flake update dotsteward --flake "$DS_INSTANCE_ROOT" </dev/null ||
      _contribute_red "upgrade: nix flake update dotsteward failed; the changes stay uncommitted, run upgrade again"
    _contribute_verify_lock "$tag" "$commit"
    _contribute_refresh_template "$tag"
    _contribute_pinned sync ||
      _contribute_red "upgrade: dotsteward sync failed; the changes stay uncommitted, run upgrade again"
    git -C "$DS_INSTANCE_ROOT" add -A
    _contribute_pinned gate --scope maintain ||
      _contribute_red "upgrade: the gate failed on the upgraded instance; the changes stay uncommitted (staged), nothing is published"
    if git -C "$DS_INSTANCE_ROOT" diff --cached --quiet; then
      log "the instance already uses $tag"
    else
      subject=${DS_COMMIT_UPGRADE_SUBJECT//\{version\}/${tag#v}}
      git -C "$DS_INSTANCE_ROOT" commit --quiet -m "$subject" </dev/null ||
        _contribute_red "upgrade: git commit failed in the instance"
      log "committed: $subject"
    fi
    instance_commit=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
    # shellcheck disable=SC2016 # jq variables
    _contribute_set '.instance_commit = $commit' --arg commit "$instance_commit"
  else
    log "resuming the upgrade at the instance commit ${instance_commit:0:12}"
  fi

  if ((build_only)); then
    _contribute_pinned rebuild --profile "$profile" --build-only ||
      _contribute_red "upgrade: rebuild --build-only failed; run upgrade again once it is fixed"
  else
    _contribute_pinned rebuild --profile "$profile" --switch ||
      _contribute_red "upgrade: rebuild --switch failed; run upgrade again once it is fixed"
    # The upgraded generation replaces whatever a failed recovery left.
    _contribute_set '.trial_switched = false | if .recovery == "failed" then .recovery = null else . end'
    if [[ $instance_commit == "$base" ]]; then
      _contribute_pinned e2e --profile "$profile" ||
        _contribute_red "upgrade: e2e failed on the upgraded instance; run upgrade again once it is fixed"
    else
      _contribute_pinned e2e --profile "$profile" --expected-remote-base "$base" ||
        _contribute_red "upgrade: e2e failed on the upgraded instance; run upgrade again once it is fixed"
    fi
  fi
  if [[ $instance_commit == "$base" ]]; then
    log "nothing to publish: the instance's published commit ${base:0:12} already uses $tag"
  else
    _contribute_pinned update publish --scope maintain --expected-base "$base" ||
      _contribute_red "upgrade: update publish failed; run upgrade again once it is fixed"
  fi
  if ((build_only)) && [[ $(_contribute_get trial_switched) == true ]]; then
    warn "the live generation still uses the trial framework (a build-only upgrade does not switch); switch to the upgraded instance with: dotsteward rebuild --profile $profile --switch"
  fi
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.upgrade = $kind | .step = "report"' --arg kind "$kind"
  log "upgraded the instance to $tag (${instance_commit:0:12}, $kind)"
  log "next: dotsteward contribute report"
}

# --- abort --------------------------------------------------------------------------

contribute_cmd_abort() {
  local id=""
  while (($#)); do
    case $1 in
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  [[ $CT_STEP != "done" ]] || die "run $id is already finished"
  _contribute_recover || die "abort stopped: the recovery did not finish; run abort again once the problem is fixed"
  _contribute_set '.step = "done" | .outcome = "aborted"'
  log "aborted run $id at step $CT_STEP"
  local pr merged
  pr=$(_contribute_get pr)
  merged=$(_contribute_get merged_sha)
  if [[ -n $merged ]]; then
    log "already published: ${merged:0:12} stays on main"
  elif [[ -n $pr ]]; then
    log "the pull request $pr stays open; close it if it is no longer wanted"
  fi
}

# --- report -------------------------------------------------------------------------

contribute_cmd_report() {
  local id="" json=0
  while (($#)); do
    case $1 in
      --json) json=1 ;;
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  case $CT_STEP in
    report) _contribute_set '.step = "done" | .outcome = "completed"' ;;
    done) ;;
    *) die "run $id has no report yet; next: $(_contribute_next_command "$CT_STEP")" ;;
  esac
  local release_url="" tag
  tag=$(_contribute_get tag)
  if [[ $CT_RUN_MODE == owner && -n $tag ]]; then
    _contribute_load_context
    _contribute_load_upstream
    [[ -z $CT_UPSTREAM_SLUG ]] || release_url=https://github.com/$CT_UPSTREAM_SLUG/releases/tag/$tag
  fi
  local document
  document=$(contribute_state_read "$id" | jq -c --arg release_url "$release_url" '{
      schema_version: 1, id, slug, mode, outcome: (.outcome // null), pr, merged_sha, tag,
      release_url: (if $release_url == "" then null else $release_url end), instance_commit,
      tests: {gate: (if .test_sha then "passed" else null end), tested_commit: .test_sha,
              tested_tree: .tested_tree, trial: (.trial // null), upgrade: (.upgrade // null)},
      trial_switched, recovery: (.recovery // null)}')
  if ((json)); then
    jq --indent 2 . <<<"$document"
    return 0
  fi
  log "contribute run $id: $(jq -r '.outcome // "unfinished"' <<<"$document")"
  jq -r '
    def show: if . == null then "none" else tostring end;
    "  mode: \(.mode)",
    "  pull request: \(.pr | show)",
    "  merged commit: \(.merged_sha | show)",
    "  release: \(.tag | show)\(if .release_url then " (\(.release_url))" else "" end)",
    "  instance commit: \(.instance_commit | show)",
    "  framework gate: \(.tests.gate | show) at \(.tests.tested_commit | show)",
    "  trial: \(.tests.trial | show)",
    "  upgrade: \(.tests.upgrade | show)",
    "  recovery after the trial switch: \(.recovery | show)"' <<<"$document"
}
