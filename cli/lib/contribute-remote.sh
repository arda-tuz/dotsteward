# shellcheck shell=bash
# The remote steps of `dotsteward contribute` and the recovery after a trial
# switch: trial, publish, release, upgrade, abort and report. Sourced by
# cli/commands/contribute.sh after cli/lib/contribute-local.sh, whose helpers
# and CT_* facts it uses; framework_root is the framework source of the running
# CLI.
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
#                            GitHub repository FORK (owner/repo) when given;
#                            _contribute_flake_url does the same for a
#                            commit on main (github:owner/repo/<commit> or
#                            ?ref=refs/heads/main&rev=<commit>)
#   contribute_main_ci_json ID
#                            main's CI for the merged commit of run ID as one
#                            JSON object (for `contribute status`)
#
# The instance commands (gate, rebuild, e2e, update, sync) run with
# DOTSTEWARD_FRAMEWORK_OVERRIDE removed from their environment, so a
# framework override is exactly the --framework-override flag the trial
# passes and never leaks into the recovery or the upgrade. They run
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
#   upgrade_to       the release tag, or main: the upgrade follows the
#                    merged commit on main (upgrade --main)
#   instance_base    the instance commit the upgrade started from (the
#                    remote branch at `update prepare`)
#   upgrade_commit   the framework upgrade commit of the instance
#   carry            the instance commits carried across the upgrade
#                    (upgrade --carry): head (the saved HEAD, also kept as
#                    refs/dotsteward/carry/<id> until the upgrade is done),
#                    remote, commits (oldest first) and applied
#   recovery         done or failed: the last recovery after a trial switch
#   outcome          completed (report after the upgrade), published (report
#                    of a run that ends at publish: no release tag and no
#                    instance commit) or aborted (abort)
#
# Environment (seconds, positive integers):
#   DOTSTEWARD_CONTRIBUTE_POLL_SECONDS    polling interval for CI (default 15),
#                                         and the first pause before a
#                                         failed read of a CI run is made
#                                         again (the pause doubles)
#   DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS  how long CI may take to appear on a
#                                         pushed commit, and how long the
#                                         reads of a CI run may keep failing
#                                         (default 300)
#   DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS
#                                         how long CI may take to finish
#                                         (default 7200)

# shellcheck disable=SC2154 # framework_root, CT_* and the CONTRIBUTE_* constants come from the dispatcher and contribute-local.sh

# The exit status of a run sent back to `check`: the branch was rebased onto
# the moved upstream main (or must be), so the tested commit is gone.
CONTRIBUTE_RESTART=5
# The workflow that exercises a change with a real activation.
CONTRIBUTE_CLEAN_INSTALL=clean-install.yml
# The checks publish waits for on the pull request head, as WORKFLOW/JOB
# (the workflow's name, the job's check name): lint of ci.yml and the
# generic scans of privacy.yml. The full check (the check job of ci.yml)
# runs on main after the merge, not on a pull request of the repository
# itself; release waits for it.
CONTRIBUTE_PUBLISH_CHECKS=(ci/lint privacy/generic)
# The workflows whose push runs on main are main's CI for a commit (lint and
# the full check, the privacy scans with the denylist): release needs them
# green, status shows them.
CONTRIBUTE_MAIN_WORKFLOWS=(ci.yml privacy.yml)

export GH_PROMPT_DISABLED=1

# shellcheck source=cli/lib/release.sh
source "$lib_dir/release.sh"

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
    upgrade) _contribute_upgrade_command ;;
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

# _contribute_waiting_base: CT_WAITING_BASE, origin/<branch> of the instance
# (read now) when HEAD is ahead of it: instance commits that wait for this
# run's fix (a maintain transaction the framework defect blocked; the
# upgrade carries them with --carry), so e2e checks the remote against it
# (--expected-remote-base) instead of HEAD. Empty when HEAD equals it, and
# for any other state, which e2e reports itself.
_contribute_waiting_base() {
  local branch=${DS_INSTANCE_BRANCH:-main} head remote count
  CT_WAITING_BASE=""
  head=$(git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet HEAD) || return 0
  remote=$(git_net 60 -C "$DS_INSTANCE_ROOT" ls-remote origin "refs/heads/$branch" </dev/null |
    awk -v ref="refs/heads/$branch" '$2 == ref { print $1; exit }') || return 0
  [[ -n $remote && $remote != "$head" ]] || return 0
  git -C "$DS_INSTANCE_ROOT" merge-base --is-ancestor "$remote" "$head" 2>/dev/null || return 0
  count=$(git -C "$DS_INSTANCE_ROOT" rev-list --count "$remote..$head")
  log "the instance has $count commit(s) that origin/$branch lacks (waiting for this fix): e2e checks origin/$branch at ${remote:0:12}, an ancestor of HEAD"
  CT_WAITING_BASE=$remote
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
  else
    _contribute_waiting_base
    [[ -z $CT_WAITING_BASE ]] || e2e+=(--expected-remote-base "$CT_WAITING_BASE")
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

# CT_KEEP_TRIAL: 1 in release, whose red outcomes keep a trial switch: the
# change is merged with the tested tree, so the trial framework of the live
# generation is what main has, and the upgrade (or the recovery of abort and
# report, when they end the run) moves it on.
CT_KEEP_TRIAL=0

# _contribute_red MESSAGE: a red step: the message, the recovery after a
# trial switch (unless CT_KEEP_TRIAL), exit 1.
_contribute_red() {
  printf '[dotsteward] ERROR: %s\n' "$1" >&2
  if ((CT_KEEP_TRIAL)); then
    [[ $(_contribute_get trial_switched) != true ]] ||
      log "the live generation keeps the trial framework: the change is merged with the tested tree, so no recovery runs; run the step again once the cause is fixed, or end the run with abort or report, which return the machine to the pinned framework"
  else
    _contribute_recover || true
  fi
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
    local -a remote_base=()
    _contribute_waiting_base
    [[ -z $CT_WAITING_BASE ]] || remote_base=(--expected-remote-base "$CT_WAITING_BASE")
    _contribute_instance e2e --profile "$profile" "${remote_base[@]}" --framework-override "$ref" ||
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

# _contribute_rebase_onto_merged REMOTE: after a pull request merged on GitHub
# (by hand, as a new squash or merge commit) whose commit is not the tested
# tree: the run goes back to check. The branch is rebased onto REMOTE/main
# (fetched): its commits are in the merge commit, so it becomes REMOTE/main; a
# conflicting rebase is aborted and the branch reset to REMOTE/main, which
# already holds the change. The merged pull request stays recorded (publish then
# takes the re-checked commit on REMOTE/main as published), unless the branch
# keeps commits that REMOTE/main lacks: those need a new pull request. No
# recovery: the run continues at check; exits with CONTRIBUTE_RESTART.
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

# _contribute_release_tags: the stable release tags of origin (and, in fork
# mode, of the upstream) as "TAG COMMIT" lines, annotated tags peeled; the
# commits need not be in the clone.
_contribute_release_tags() {
  local remote answer sha name
  local -a remotes=(origin)
  [[ $CT_RUN_MODE != fork ]] || remotes+=(upstream)
  for remote in "${remotes[@]}"; do
    answer=$(git_net 60 -C "$CT_CLONE" ls-remote --tags "$remote" 'refs/tags/v*') ||
      die "cannot list the tags of $remote"
    # Peeled lines (TAG^{}) first, so they win over the tag objects.
    while IFS=$'\t' read -r sha name; do
      [[ -n ${sha:-} ]] || continue
      name=${name#refs/tags/}
      if [[ $name == *'^{}' ]]; then
        printf '%s %s\n' "${name%'^{}'}" "$sha"
      fi
    done <<<"$answer"
    while IFS=$'\t' read -r sha name; do
      [[ -n ${sha:-} && $name != *'^{}' ]] || continue
      printf '%s %s\n' "${name#refs/tags/}" "$sha"
    done <<<"$answer"
  done
}

# _contribute_release_state COMMIT: CT_RELEASE (release_state of COMMIT
# with the remotes' release tags: STATE VERSION BASE NEXT MAJOR KIND
# BASE_COMMIT) as an array; red when VERSION at COMMIT is missing.
_contribute_release_state() {
  local commit=$1 line tags
  tags=$(_contribute_release_tags)
  line=$(release_state "$CT_CLONE" "$commit" "$tags") ||
    _contribute_red "VERSION at ${commit:0:12} is missing or not X.Y.Z; nothing is published"
  read -ra CT_RELEASE <<<"$line"
}

# _contribute_require_version COMMIT: VERSION at COMMIT is either the
# release the commits are based on (the run releases nothing; release
# trains: a later release bundles it) or exactly the next release
# (tools/version.sh bump: a release commit); checked before main is
# touched and again before the merge (a release cut meanwhile moves the
# next one); red otherwise.
_contribute_require_version() {
  local commit=$1
  _contribute_release_state "$commit"
  case ${CT_RELEASE[0]} in
    none | pending) return 0 ;;
  esac
  if [[ ${CT_RELEASE[3]} == - ]]; then
    _contribute_red "VERSION is ${CT_RELEASE[1]} at ${commit:0:12}, but the commits since v${CT_RELEASE[2]} hold a breaking change: keep VERSION ${CT_RELEASE[2]} (no release in this run), or set the next major with tools/version.sh bump --major once the user decided it; then run: dotsteward contribute check; nothing is published"
  fi
  _contribute_red "VERSION is ${CT_RELEASE[1]} at ${commit:0:12}, but it must stay ${CT_RELEASE[2]} (no release in this run) or be the next release ${CT_RELEASE[3]} (a release commit: tools/version.sh bump); fix it, then run: dotsteward contribute check; nothing is published"
}

# --- publish: CI ----------------------------------------------------------------------

# _contribute_runs REPO SHA WORKFLOW EVENT [BRANCH]: the workflow runs of
# commit SHA in REPO, newest first, as "id status conclusion url" lines;
# WORKFLOW (a file name), EVENT and BRANCH narrow them when not empty. The
# REST API also finds runs of a workflow that is not on the default branch
# yet.
_contribute_runs() {
  local repo=$1 sha=$2 workflow=$3 event=$4 branch=${5:-} answer
  answer=$(gh api -X GET "repos/$repo/actions/runs" -f head_sha="$sha" -F per_page=100 </dev/null) || return 1
  jq -r --arg workflow "$workflow" --arg event "$event" --arg branch "$branch" '
    [.workflow_runs[]?
      | select($workflow == "" or ((.path // "") | split("@")[0]) == ".github/workflows/" + $workflow)
      | select($event == "" or .event == $event)
      | select($branch == "" or .head_branch == $branch)]
    | sort_by(.created_at, .id) | reverse | .[]
    | "\(.id) \(.status) \(.conclusion // "none") \(.html_url // "")"' <<<"$answer"
}

# _contribute_ci_read WHAT COMMAND...: the output of COMMAND, a read of CI
# runs on GitHub (WHAT names them in the warnings). A failed read is not a
# CI result (the network was down for a moment, or GitHub answered HTTP
# 5xx): it is made again after a pause that starts at
# DOTSTEWARD_CONTRIBUTE_POLL_SECONDS and doubles, and status 1 (the
# caller's red) follows only once the reads kept failing for
# DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS.
_contribute_ci_read() {
  local what=$1 interval window start pause elapsed answer
  shift
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  window=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS 300)
  start=$SECONDS
  pause=$interval
  until answer=$("$@" </dev/null); do
    elapsed=$((SECONDS - start))
    ((elapsed < window)) || return 1
    ((pause <= window - elapsed)) || pause=$((window - elapsed))
    warn "cannot read $what; reading GitHub again in ${pause}s"
    sleep "$pause"
    pause=$((pause * 2))
  done
  printf '%s\n' "$answer"
}

# _contribute_wait_run REPO ID WHAT [STAKE]: waits for run ID to complete;
# red unless it concluded with success (or was skipped). STAKE ends the red
# message (default: nothing is published). A failed read of the run is
# made again (_contribute_ci_read).
_contribute_wait_run() {
  local repo=$1 run=$2 what=$3 stake=${4:-nothing is published} interval timeout start answer status conclusion url
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  timeout=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS 7200)
  start=$SECONDS
  while :; do
    answer=$(_contribute_ci_read "run $run of $what in $repo" gh api "repos/$repo/actions/runs/$run") ||
      _contribute_red "cannot read run $run of $what in $repo"
    read -r status conclusion url < <(jq -r '"\(.status) \(.conclusion // "none") \(.html_url // "")"' <<<"$answer")
    [[ $status != completed ]] || break
    ((SECONDS - start < timeout)) || _contribute_red "$what did not finish within ${timeout}s: $url; $stake"
    sleep "$interval"
  done
  case $conclusion in
    success | skipped | neutral) log "$what: $conclusion ($url)" ;;
    *) _contribute_red "$what concluded with $conclusion: $url; $stake" ;;
  esac
}

# _contribute_pr_checks PR FIELDS: the checks of PR as "WORKFLOW/NAME[=BUCKET]"
# lines (FIELDS: name,workflow or name,workflow,bucket); status 1 when they
# cannot be read.
_contribute_pr_checks() {
  local pr=$1 fields=$2
  gh pr checks "$pr" --json "$fields" \
    --jq '.[] | "\(.workflow // "")/\(.name // "")\(if .bucket then "=\(.bucket)" else "" end)"' </dev/null 2>/dev/null
}

# _contribute_publish_state LINES: the state of the CONTRIBUTE_PUBLISH_CHECKS
# among the check lines LINES (_contribute_pr_checks): "missing NAME..." when
# one has no check yet, "fail NAME..." when one failed or was cancelled,
# "pending" while one runs, else "pass". Every other check is ignored.
_contribute_publish_state() {
  local lines=$1 check line bucket seen
  local -a missing=() failed=()
  local pending=0
  for check in "${CONTRIBUTE_PUBLISH_CHECKS[@]}"; do
    seen=0
    while IFS= read -r line; do
      [[ ${line%%=*} == "$check" ]] || continue
      seen=1
      bucket=${line#*=}
      [[ $line == *=* ]] || bucket=""
      case $bucket in
        fail | cancel) failed+=("${check#*/}") ;;
        pending) pending=1 ;;
      esac
    done <<<"$lines"
    ((seen)) || missing+=("${check#*/}")
  done
  if ((${#missing[@]})); then
    printf 'missing %s\n' "${missing[*]}"
  elif ((${#failed[@]})); then
    printf 'fail %s\n' "${failed[*]}"
  elif ((pending)); then
    printf 'pending\n'
  else
    printf 'pass\n'
  fi
}

# _contribute_wait_pr_checks PR: the publish checks (CONTRIBUTE_PUBLISH_CHECKS:
# lint and the generic privacy scans) of the pushed commit appear on the pull
# request and pass. Other checks are not waited for: the full check runs on
# main after the merge and gates the release. Right after a push GitHub may
# still answer for the previous head, with its old checks, and then report
# the new head before any of its checks is registered; both count as not
# appeared yet.
_contribute_wait_pr_checks() {
  local pr=$1 interval appear timeout start head lines state names
  names="${CONTRIBUTE_PUBLISH_CHECKS[*]#*/}"
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  appear=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS 300)
  timeout=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS 7200)
  start=$SECONDS
  while :; do
    state=missing
    head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid </dev/null 2>/dev/null) || head=''
    if [[ $head == "$CT_TEST_SHA" ]] && lines=$(_contribute_pr_checks "$pr" name,workflow); then
      state=$(_contribute_publish_state "$lines")
    fi
    [[ $state == missing* ]] || break
    ((SECONDS - start < appear)) ||
      _contribute_red "the CI checks ${names// / and } did not appear on $pr within ${appear}s; publishing needs them green, main is untouched"
    sleep "$interval"
  done
  # The checks are read until none of the publish checks is pending. A
  # failed read (GitHub answers HTTP 502 at times) is not a CI result and is
  # read again; only answers that keep failing stop the wait.
  log "waiting for the CI checks ${names// / and } of $pr (the full check runs on main after the merge)"
  local failures=0 limit=10
  start=$SECONDS
  while :; do
    if lines=$(_contribute_pr_checks "$pr" name,workflow,bucket); then
      failures=0
      state=$(_contribute_publish_state "$lines")
      case $state in
        fail*)
          state=${state#fail }
          _contribute_red "CI is not green on $pr (${state// / and } failed); main is untouched"
          ;;
        pass) break ;;
      esac
    else
      failures=$((failures + 1))
      ((failures < limit)) ||
        _contribute_red "cannot read the CI checks of $pr ($failures failed answers in a row); main is untouched"
    fi
    ((SECONDS - start < timeout)) ||
      _contribute_red "the CI checks ${names// / and } of $pr did not finish within ${timeout}s; main is untouched"
    sleep "$interval"
  done
  log "CI is green on $pr: ${names// / and } passed"
}

# --- main's CI ------------------------------------------------------------------------

# contribute_main_ci_json ID: main's CI for the merged commit of run ID
# (release_main_ci of CONTRIBUTE_MAIN_WORKFLOWS: {sha, state, url, runs}),
# read once; {sha, state: "unknown", url: null, reason, runs: []} when it
# cannot be read (no merged commit, gh missing or logged out, no answer).
# Never fails and never waits.
contribute_main_ci_json() {
  local id=$1 answer errors sha
  errors=$(mktemp "${TMPDIR:-/tmp}/dotsteward-main-ci.XXXXXX")
  if answer=$(
    exec 2>"$errors"
    _contribute_load_run "$id"
    sha=$(_contribute_get merged_sha)
    [[ -n $sha ]] || die "the run has no merged commit"
    _contribute_require_gh
    _contribute_remote_facts >/dev/null
    release_main_ci "$CT_PUBLISH_SLUG" "$sha" "${CONTRIBUTE_MAIN_WORKFLOWS[@]}" ||
      die "cannot list the CI runs of $CT_PUBLISH_SLUG"
  ) && [[ -n $answer ]]; then
    printf '%s\n' "$answer"
  else
    sha=$(contribute_state_get "$id" merged_sha 2>/dev/null) || sha=null
    jq -cn --arg sha "$sha" --arg reason "$(sed -n 's/^\[dotsteward\] ERROR: //p' "$errors" | tail -n 1)" \
      '{sha: (if $sha == "null" then null else $sha end), state: "unknown", url: null,
        reason: (if $reason == "" then "main CI could not be read" else $reason end), runs: []}'
  fi
  rm -f -- "$errors"
}

# _contribute_wait_main_ci SHA: main's CI for SHA (the push runs of
# CONTRIBUTE_MAIN_WORKFLOWS on main of CT_PUBLISH_SLUG, the full check among
# them) appears within DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS and concludes
# with success within DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS; red
# otherwise: a release is cut only from a main commit whose CI is green.
# A failed read of GitHub meanwhile is made again (_contribute_ci_read).
# Skipped with a warning when GitHub Actions are disabled there (a fork
# without CI).
_contribute_wait_main_ci() {
  local sha=$1 repo=$CT_PUBLISH_SLUG enabled interval appear start document line
  local -a missing=() runs=()
  enabled=$(gh api "repos/$repo/actions/permissions" </dev/null 2>/dev/null | jq -r '.enabled') || enabled=""
  if [[ $enabled == false ]]; then
    warn "GitHub Actions are disabled on $repo, so main has no CI; releasing on the framework gate and the trial"
    return 0
  fi
  interval=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_POLL_SECONDS 15)
  appear=$(_contribute_seconds DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS 300)
  start=$SECONDS
  while :; do
    document=$(_contribute_ci_read "the CI runs of ${sha:0:12} in $repo" \
      release_main_ci "$repo" "$sha" "${CONTRIBUTE_MAIN_WORKFLOWS[@]}") ||
      _contribute_red "cannot list the CI runs of ${sha:0:12} in $repo; nothing is released"
    mapfile -t missing < <(jq -r '.runs[] | select(.status == "missing") | .workflow' <<<"$document")
    mapfile -t runs < <(jq -r '.runs[] | select(.status != "missing") | "\(.workflow) \(.id)"' <<<"$document")
    ((${#missing[@]})) || break
    ((SECONDS - start < appear)) ||
      _contribute_red "no run of ${missing[*]} appeared on main of $repo for ${sha:0:12} within ${appear}s; a release needs main's CI green on its commit, nothing is released"
    sleep "$interval"
  done
  log "waiting for main's CI on ${sha:0:12} (${CONTRIBUTE_MAIN_WORKFLOWS[*]})"
  for line in "${runs[@]}"; do
    _contribute_wait_run "$repo" "${line#* }" "${line%% *} on main at ${sha:0:12}" "nothing is released"
  done
  log "main's CI is green on ${sha:0:12}"
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
      _contribute_red "main of $CT_PUBLISH_SLUG (${main:0:12}) cannot be fast-forwarded to ${CT_TEST_SHA:0:12}: it has commits that $CT_BRANCH lacks; rebase $CT_BRANCH onto it in $CT_CLONE (with TZ=UTC; the commit-msg hook refuses a merge commit with git's default subject), then run: dotsteward contribute check"
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
  _contribute_release_state "$(_contribute_get merged_sha)"
  if [[ ${CT_RELEASE[0]} == none ]]; then
    log "no release is pending (VERSION is still ${CT_RELEASE[2]}): the next release bundles this run"
    log "next: dotsteward contribute upgrade --main (the instance follows the merged commit), or dotsteward contribute report"
  else
    log "next: dotsteward contribute release"
  fi
}

# --- release ------------------------------------------------------------------------

# _contribute_origin_tag TAG MERGED: CT_ORIGIN_TAG, the commit of TAG on
# origin (an annotated tag peeled), empty without that tag; red, with
# nothing changed, when it names a commit other than MERGED.
_contribute_origin_tag() {
  local tag=$1 merged=$2
  CT_ORIGIN_TAG=$(_contribute_remote_ref origin "refs/tags/$tag") ||
    _contribute_red "cannot read the tags of origin; nothing is released"
  [[ -z $CT_ORIGIN_TAG || $CT_ORIGIN_TAG == "$merged" ]] ||
    _contribute_red "the tag $tag already exists on origin at ${CT_ORIGIN_TAG:0:12}, not at the merged commit ${merged:0:12}; nothing is released"
}

# _contribute_release_notes TAG COMMIT FILE: the grouped release notes
# (release_notes) of the commits of COMMIT after the release before TAG,
# written to FILE.
_contribute_release_notes() {
  local tag=$1 commit=$2 file=$3 tags base text
  tags=$(_contribute_release_tags)
  base=$(release_base_before "$CT_CLONE" "$commit" "$tag" "$tags")
  text=$(release_notes "$CT_CLONE" "$base" "$commit") || _contribute_red "cannot write the release notes of $tag"
  printf '%s\n' "$text" >"$file"
}

contribute_cmd_release() {
  local id="" major=0
  while (($#)); do
    case $1 in
      --major) major=1 ;;
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
  # The change is merged: a red outcome from here on keeps a trial switch.
  CT_KEEP_TRIAL=1
  local merged tag local_tag remote_tag notes
  merged=$(_contribute_get merged_sha)
  [[ -n $merged ]] || die "run $id has no merged commit; run: dotsteward contribute publish"
  contribute_is_clone "$CT_CLONE" || die "the clone $CT_CLONE of run $id is missing"
  [[ $CT_RUN_MODE != owner ]] || _contribute_require_gh
  _contribute_remote_facts
  git -C "$CT_CLONE" cat-file -e "$merged^{commit}" 2>/dev/null || contribute_fetch_main "$CT_CLONE" origin
  git -C "$CT_CLONE" cat-file -e "$merged^{commit}" 2>/dev/null || die "the merged commit ${merged:0:12} is not in $CT_CLONE"

  # The release is the one VERSION of the merged commit names: a release
  # commit set it to the next version (release trains). A merged commit
  # whose VERSION is still its base release has nothing to release here,
  # unless that release is the merged commit itself: the release workflow
  # (release.yml) cuts a pending release by itself once main's CI is green,
  # possibly before this step, and its tag is then the run's release.
  tag=$(_contribute_get tag)
  if [[ -z $tag ]]; then
    _contribute_release_state "$merged"
    case ${CT_RELEASE[0]} in
      none)
        [[ ${CT_RELEASE[6]} == "$merged" ]] ||
          die "no release is pending at the merged commit ${merged:0:12}: VERSION is still ${CT_RELEASE[2]}, the release it is based on, so the next release bundles it (release trains); follow it with: dotsteward contribute upgrade --main, or end the run with: dotsteward contribute report"
        tag=v${CT_RELEASE[2]}
        log "the merged commit ${merged:0:12} carries its release tag $tag already (cut by the release workflow or by hand)"
        # Recorded only once main's CI is green on it, as for a tag this
        # step cuts itself.
        _contribute_wait_main_ci "$merged"
        ;;
      mismatch)
        if [[ ${CT_RELEASE[3]} == - ]]; then
          _contribute_red "VERSION is ${CT_RELEASE[1]} at the merged commit ${merged:0:12}, but the commits since v${CT_RELEASE[2]} hold a breaking change, which needs the next major release (tools/version.sh bump --major, a decision of the user); nothing is released"
        fi
        _contribute_red "VERSION is ${CT_RELEASE[1]} at the merged commit ${merged:0:12}, but the next release is v${CT_RELEASE[3]} (after v${CT_RELEASE[2]}, as the commits decide): set it with tools/version.sh bump in a release commit; nothing is released"
        ;;
    esac
    if [[ -z $tag ]]; then
      ((CT_RELEASE[4] == 0 || major)) ||
        die "v${CT_RELEASE[1]} is a major release: cut it only with dotsteward contribute release --major, a decision of the user; nothing is released"
      tag=v${CT_RELEASE[1]}
    fi
  fi

  # The tag on origin, read again once main's CI is green: the release
  # workflow cuts the same release as soon as that CI passes, so it may
  # cut it while this step waits, or between the read and the push. A tag
  # on the merged commit is the run's release (no push, no second GitHub
  # release); a tag elsewhere is red with nothing changed.
  _contribute_origin_tag "$tag" "$merged"
  remote_tag=$CT_ORIGIN_TAG
  if [[ -z $remote_tag ]]; then
    # A release is cut only from a main commit whose CI is green: the full
    # check ran on main after the merge, not on the pull request. A tag
    # already on origin (an interrupted release, or one the release
    # workflow cut) was recorded after that wait.
    _contribute_wait_main_ci "$merged"
    _contribute_origin_tag "$tag" "$merged"
    remote_tag=$CT_ORIGIN_TAG
    [[ -z $remote_tag ]] ||
      log "the release workflow cut $tag on ${merged:0:12} while this step waited for main's CI: it is the run's release"
  fi
  local_tag=$(git -C "$CT_CLONE" rev-parse --verify --quiet "refs/tags/$tag^{commit}") || local_tag=""
  [[ -z $local_tag || $local_tag == "$merged" ]] ||
    _contribute_red "the local tag $tag points at ${local_tag:0:12}, not at the merged commit ${merged:0:12}; delete it in $CT_CLONE"
  if [[ -z $remote_tag ]]; then
    if [[ -z $local_tag ]]; then
      TZ=UTC git -C "$CT_CLONE" tag -a "$tag" -m "dotsteward $tag" "$merged" ||
        _contribute_red "cannot create the tag $tag"
    fi
    if git_net 180 -C "$CT_CLONE" push --quiet origin "refs/tags/$tag:refs/tags/$tag" </dev/null; then
      log "tagged ${merged:0:12} as $tag on $CT_PUBLISH_SLUG"
    else
      _contribute_origin_tag "$tag" "$merged"
      remote_tag=$CT_ORIGIN_TAG
      [[ -n $remote_tag ]] || _contribute_red "pushing the tag $tag to origin failed"
      log "the release workflow cut $tag on ${merged:0:12} first: it is the run's release"
    fi
  fi
  if [[ -n $remote_tag ]]; then
    # origin's tag replaces a local one on the same commit (the workflow's
    # tag is a lightweight one), so later fetches of the tags agree.
    git_net 60 -C "$CT_CLONE" fetch --quiet origin "+refs/tags/$tag:refs/tags/$tag" </dev/null ||
      _contribute_red "cannot fetch the tag $tag"
  fi
  if [[ $CT_RUN_MODE == owner ]]; then
    if gh release view "$tag" -R "$CT_PUBLISH_SLUG" --json tagName </dev/null >/dev/null 2>&1; then
      log "the release $tag exists"
    else
      notes=$(mktemp "${TMPDIR:-/tmp}/dotsteward-notes.XXXXXX")
      _contribute_release_notes "$tag" "$merged" "$notes"
      if gh release create "$tag" -R "$CT_PUBLISH_SLUG" --title "$tag" --notes-file "$notes" --verify-tag </dev/null >/dev/null; then
        log "released $tag: https://github.com/$CT_PUBLISH_SLUG/releases/tag/$tag"
      elif gh release view "$tag" -R "$CT_PUBLISH_SLUG" --json tagName </dev/null >/dev/null 2>&1; then
        log "the release $tag exists: the release workflow created it meanwhile"
      else
        rm -f -- "$notes"
        _contribute_red "gh release create $tag failed"
      fi
      rm -f -- "$notes"
    fi
  fi
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.tag = $tag | .step = "upgrade"' --arg tag "$tag"
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

# _contribute_flake_url URL KIND VALUE [FORK]: the dotsteward input URL URL
# moved to the release tag VALUE (KIND tag) or to the commit VALUE on main
# (KIND rev), on the GitHub repository FORK (owner/repo) when given; status
# 1 for a URL of another form.
_contribute_flake_url() {
  local url=$1 kind=$2 value=$3 fork=${4:-} rest query="" path base host
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
      # A tag or a 40-digit commit in the path: Nix reads the commit as rev.
      printf 'github:%s/%s%s\n' "$path" "$value" "${query:+?$query}"
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
      # Always the full ref: Nix reads a git+ ref without refs/ as a branch
      # (refs/heads/<ref>), whatever the url had before. A commit is fetched
      # from main, where publish put it.
      if [[ $kind == tag ]]; then
        printf '%s?%sref=refs/tags/%s\n' "$base" "${query:+$query&}" "$value"
      else
        printf '%s?%sref=refs/heads/main&rev=%s\n' "$base" "${query:+$query&}" "$value"
      fi
      ;;
    *) return 1 ;;
  esac
}

contribute_flake_url_for_tag() {
  _contribute_flake_url "$1" tag "$2" "${3:-}"
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

# _contribute_set_framework_url KIND VALUE FORK: the dotsteward input of the
# instance flake.nix moved to the tag VALUE (KIND tag) or the commit VALUE
# on main (KIND rev), on FORK when not empty.
_contribute_set_framework_url() {
  local kind=$1 value=$2 fork=$3 flake=$DS_INSTANCE_ROOT/flake.nix found line url new tmp target
  target="the tag $value"
  [[ $kind == tag ]] || target="the commit $value of main"
  [[ -f $flake ]] || _contribute_red "the instance has no flake.nix"
  found=$(_contribute_flake_url_line "$flake") ||
    _contribute_red "cannot find the one url of the dotsteward input in $flake; set it to $target by hand and run upgrade again"
  line=${found%%$'\t'*}
  url=${found#*$'\t'}
  new=$(_contribute_flake_url "$url" "$kind" "$value" "$fork") ||
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

# _contribute_verify_lock KIND VALUE COMMIT LABEL: the instance flake.lock
# locks the dotsteward input at COMMIT, from the reference VALUE: the tag
# (KIND tag) or that commit itself (KIND rev).
_contribute_verify_lock() {
  local kind=$1 value=$2 commit=$3 label=$4 answer ref rev original
  answer=$(jq -r '
    .nodes[.root].inputs.dotsteward as $name
    | if ($name | type) != "string" then empty else .nodes[$name] end
    | "\(.original.ref // "")|\(.original.rev // "")|\(.locked.rev // "")"' "$DS_INSTANCE_ROOT/flake.lock" 2>/dev/null) ||
    answer=""
  IFS='|' read -r ref original rev <<<"$answer"
  if [[ $kind == tag ]]; then
    [[ ${ref#refs/tags/} == "$value" && $rev == "$commit" ]] ||
      _contribute_red "flake.lock locks dotsteward ${ref:-without a ref} at ${rev:-no revision}, not $label at ${commit:0:12}; the upgrade stops before any commit"
  else
    [[ $original == "$value" && $rev == "$commit" ]] ||
      _contribute_red "flake.lock locks dotsteward ${original:-${ref:-without a revision}} at ${rev:-no revision}, not $label; the upgrade stops before any commit"
  fi
  log "flake.lock: dotsteward $label at ${commit:0:12}"
}

# _contribute_refresh_template REV LABEL: bootstrap.sh and .dotsteward/cli.sh
# of the instance from template/ of the framework at REV (the release tag
# or the commit on main; LABEL in messages), the files `dotsteward static`
# keeps byte-identical to the pinned framework's.
_contribute_refresh_template() {
  local rev=$1 label=$2 path mode target tmp
  for path in bootstrap.sh .dotsteward/cli.sh; do
    mode=$(git -C "$CT_CLONE" ls-tree "$rev" -- "template/$path" | awk '{print $1}')
    [[ -n $mode ]] || continue
    target=$DS_INSTANCE_ROOT/$path
    mkdir -p -- "$(dirname -- "$target")"
    tmp=$(mktemp "$(dirname -- "$target")/.refresh.XXXXXX")
    git -C "$CT_CLONE" show "$rev:template/$path" >"$tmp" || {
      rm -f -- "$tmp"
      _contribute_red "cannot read template/$path of $label"
    }
    if [[ $mode == 100755 ]]; then chmod 0755 "$tmp"; else chmod 0644 "$tmp"; fi
    if [[ -f $target ]] && cmp -s -- "$tmp" "$target"; then
      rm -f -- "$tmp"
      continue
    fi
    mv -f -- "$tmp" "$target"
    log "refreshed $path from template/$path of $label"
  done
}

# --- upgrade: carried instance commits ----------------------------------------------

# The generated mirrors of the instance (`dotsteward sync` writes them; keep
# identical to mirror_name_pattern of cli/commands/sync.sh).
CONTRIBUTE_MIRROR_PATH='^\.dotsteward/(manifest\.[A-Za-z0-9_-]+\.json|stage0\.[a-z]+\.env)$'

# _contribute_carry_ref: the ref that keeps the carried instance commits of
# the run reachable while the instance is reset.
_contribute_carry_ref() {
  printf 'refs/dotsteward/carry/%s\n' "$CT_RUN_ID"
}

# _contribute_upgrade_command: the command that continues the upgrade.
_contribute_upgrade_command() {
  local command="dotsteward contribute upgrade"
  if [[ $(_contribute_get upgrade_to) == main ]]; then
    command+=" --main"
  else
    command+=" --tag $(_contribute_get tag)"
  fi
  [[ -z $(_contribute_get carry) ]] || command+=" --carry"
  printf '%s\n' "$command"
}

# _contribute_carry_prepare CARRY(0|1): the instance HEAD equals
# origin/<branch> (fetched now) before the upgrade starts. Instance commits
# that origin lacks (a maintain transaction that waits for this fix) are
# refused, naming --carry; with CARRY=1 they are saved (state carry: head,
# remote and the commits oldest first, kept reachable by
# refs/dotsteward/carry/<run id>) and the instance is reset to
# origin/<branch>, so the upgrade starts from the published instance and
# applies them again on top of its commit.
_contribute_carry_prepare() {
  local carry=$1 branch=$DS_INSTANCE_BRANCH head remote count commits
  head=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
  git_net 60 -C "$DS_INSTANCE_ROOT" fetch --quiet origin "$branch" </dev/null ||
    die "could not fetch origin/$branch of the instance within 60 s"
  remote=$(git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") ||
    die "origin/$branch of the instance is missing after the fetch"
  [[ $head != "$remote" ]] || return 0
  count=$(git -C "$DS_INSTANCE_ROOT" rev-list --count "$remote..$head")
  if ((carry == 0)); then
    ((count > 0)) ||
      die "the instance HEAD ${head:0:12} is behind origin/$branch (${remote:0:12}); run 'git pull --ff-only' in $DS_INSTANCE_ROOT first"
    die "the instance HEAD ${head:0:12} differs from origin/$branch (${remote:0:12}): $count unpublished commit(s) that origin lacks; publish or remove them first, or carry them across the upgrade with: $(_contribute_upgrade_command) --carry"
  fi
  if ((count == 0)); then
    git -C "$DS_INSTANCE_ROOT" merge --quiet --ff-only "$remote" ||
      die "cannot fast-forward the instance to origin/$branch"
    log "the instance was behind origin/$branch: fast-forwarded to ${remote:0:12}, nothing to carry"
    return 0
  fi
  (($(git -C "$DS_INSTANCE_ROOT" rev-list --count --merges "$remote..$head") == 0)) ||
    die "the unpublished instance commits include a merge; --carry carries a line of commits only: rebase them onto origin/$branch first"
  commits=$(git -C "$DS_INSTANCE_ROOT" rev-list --reverse "$remote..$head" | jq -Rsc 'split("\n") | map(select(length > 0))')
  git -C "$DS_INSTANCE_ROOT" update-ref "$(_contribute_carry_ref)" "$head" ||
    die "cannot save the carried commits as $(_contribute_carry_ref)"
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.carry = {head: $head, remote: $remote, commits: $commits, applied: false}' \
    --arg head "$head" --arg remote "$remote" --argjson commits "$commits"
  git -C "$DS_INSTANCE_ROOT" reset --quiet --hard "$remote" ||
    die "cannot reset the instance to origin/$branch; the carried commits are saved as $(_contribute_carry_ref)"
  log "carrying $count unpublished instance commit(s) across the upgrade: saved as $(_contribute_carry_ref) (${head:0:12}); the upgrade starts from origin/$branch (${remote:0:12})"
}

# _contribute_carry_conflicts: the conflicted paths of the instance, one per
# line.
_contribute_carry_conflicts() {
  git -C "$DS_INSTANCE_ROOT" diff --name-only --diff-filter=U
}

# _contribute_carry_apply UPGRADE_COMMIT: the carried commits applied again
# on top of the upgrade commit (git cherry-pick, TZ=UTC; their messages and
# authors kept). A conflict in the generated mirrors only is resolved with
# the upgrade's mirrors, which sync regenerates next (a commit left empty by
# that is dropped); any other conflict stops the upgrade with the
# cherry-pick in progress, to be resolved by hand and continued with `git
# cherry-pick --continue` before the upgrade runs again. A HEAD above the
# upgrade commit with no cherry-pick in progress holds them.
_contribute_carry_apply() {
  local upgrade_commit=$1 head path paths count guard=0
  local -a commits=() real=()
  if git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null ||
    [[ -d $(git -C "$DS_INSTANCE_ROOT" rev-parse --absolute-git-dir)/sequencer ]]; then
    die "carrying the instance commits stopped on a conflict in $DS_INSTANCE_ROOT: resolve it, git add the files and run 'git cherry-pick --continue' there (repeat until it is done; 'git cherry-pick --abort' starts the carry over), then run: $(_contribute_upgrade_command)"
  fi
  [[ $(contribute_state_read "$CT_RUN_ID" | jq -r '.carry.applied // false') != true ]] || return 0
  head=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
  if [[ $head != "$upgrade_commit" ]]; then
    git -C "$DS_INSTANCE_ROOT" merge-base --is-ancestor "$upgrade_commit" "$head" ||
      die "the instance moved off the upgrade commit ${upgrade_commit:0:12} (HEAD ${head:0:12}); restore it, or end the run with: dotsteward contribute abort"
    log "the carried commits are on top of the upgrade commit (${head:0:12})"
  else
    mapfile -t commits < <(contribute_state_read "$CT_RUN_ID" | jq -r '.carry.commits[]')
    count=${#commits[@]}
    if ((count)); then
      log "carrying ${count} instance commit(s) onto the upgrade commit ${upgrade_commit:0:12}"
      if ! (cd -- "$DS_INSTANCE_ROOT" && TZ=UTC git cherry-pick "${commits[@]}") </dev/null >/dev/null 2>&1; then
        git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null ||
          die "git cherry-pick of the carried commits failed in $DS_INSTANCE_ROOT; they stay saved as $(_contribute_carry_ref)"
        while git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null; do
          ((++guard <= 2 * count + 2)) ||
            die "carrying the instance commits does not finish in $DS_INSTANCE_ROOT; finish the cherry-pick by hand ('git cherry-pick --continue', or --abort to start over), then run: $(_contribute_upgrade_command)"
          paths=$(_contribute_carry_conflicts)
          real=()
          while IFS= read -r path; do
            [[ -z $path || $path =~ $CONTRIBUTE_MIRROR_PATH ]] || real+=("$path")
          done <<<"$paths"
          if ((${#real[@]})) || { [[ -z $paths ]] && ! git -C "$DS_INSTANCE_ROOT" diff --cached --quiet; }; then
            die "carrying the instance commit $(git -C "$DS_INSTANCE_ROOT" rev-parse --short=12 CHERRY_PICK_HEAD) conflicts with the upgrade in ${real[*]:-the instance}: resolve it in $DS_INSTANCE_ROOT, git add the files and run 'git cherry-pick --continue' (repeat until it is done; 'git cherry-pick --abort' starts the carry over), then run: $(_contribute_upgrade_command)"
          fi
          # Only generated mirrors conflict: the upgrade's stay, sync
          # regenerates them from the carried changes next.
          while IFS= read -r path; do
            [[ -n $path ]] || continue
            git -C "$DS_INSTANCE_ROOT" checkout --quiet HEAD -- "$path" 2>/dev/null ||
              git -C "$DS_INSTANCE_ROOT" rm --quiet -f -- "$path"
          done <<<"$paths"
          # A commit left empty (its change is in the upgrade already) is
          # dropped; any other one continues the sequence.
          if git -C "$DS_INSTANCE_ROOT" diff --cached --quiet; then
            (cd -- "$DS_INSTANCE_ROOT" && TZ=UTC git cherry-pick --skip) </dev/null >/dev/null 2>&1 || true
          else
            (cd -- "$DS_INSTANCE_ROOT" && TZ=UTC GIT_EDITOR=true git cherry-pick --continue) </dev/null >/dev/null 2>&1 || true
          fi
        done
        [[ ! -d $(git -C "$DS_INSTANCE_ROOT" rev-parse --absolute-git-dir)/sequencer ]] ||
          die "carrying the instance commits stopped in $DS_INSTANCE_ROOT: finish the cherry-pick by hand ('git cherry-pick --continue', or --abort to start over), then run: $(_contribute_upgrade_command)"
      fi
    fi
  fi
  _contribute_set '.carry.applied = true'
}

# _contribute_carry_finish: after the carried commits: sync (their mirrors
# from the upgraded framework, folded into the last carried commit when
# they changed) and the gate of the whole tree, which publish needs.
_contribute_carry_finish() {
  _contribute_pinned sync ||
    _contribute_red "upgrade: dotsteward sync failed on the carried commits; fix them, then run: $(_contribute_upgrade_command)"
  git -C "$DS_INSTANCE_ROOT" add -A
  if ! git -C "$DS_INSTANCE_ROOT" diff --cached --quiet; then
    (cd -- "$DS_INSTANCE_ROOT" && TZ=UTC git commit --quiet --amend --no-edit) </dev/null ||
      _contribute_red "upgrade: cannot fold the synced mirrors into the last carried commit"
    log "folded the synced mirrors into the last carried commit"
  fi
  _contribute_pinned gate --scope maintain ||
    _contribute_red "upgrade: the gate failed on the carried commits; fix them (a new commit or an amend), then run: $(_contribute_upgrade_command)"
}

# --- upgrade ------------------------------------------------------------------------

contribute_cmd_upgrade() {
  local id="" tag_option="" build_only=0 main=0 carry=0
  while (($#)); do
    case $1 in
      --tag)
        need_value "$1" "$#" "${2:-}"
        tag_option=$2
        shift
        ;;
      --main) main=1 ;;
      --carry) carry=1 ;;
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
  [[ -z $tag_option ]] || ((main == 0)) || die "--tag and --main exclude each other"
  contribute_load_config
  id=$(contribute_run_id "$id")
  _contribute_load_run "$id"
  case $CT_STEP in
    upgrade | release) ;;
    report | done)
      log "run $id already upgraded the instance: $(_contribute_get instance_commit)"
      return 0
      ;;
    *) die "run $id is not published yet; next: $(_contribute_next_command "$CT_STEP")" ;;
  esac
  local tag merged commit recorded label version kind rev
  tag=$(_contribute_get tag)
  merged=$(_contribute_get merged_sha)
  recorded=$(_contribute_get upgrade_to)
  if [[ $recorded == main ]]; then
    [[ -z $tag_option ]] || die "the upgrade of run $id follows its merged commit on main; run: $(_contribute_upgrade_command)"
    main=1
  elif [[ -n $recorded ]] && ((main)); then
    die "the upgrade of run $id moves the instance to $recorded; run: $(_contribute_upgrade_command)"
  fi
  [[ -n $(_contribute_get carry) ]] || [[ -z $(_contribute_get instance_base) ]] || ((carry == 0)) ||
    die "the upgrade of run $id started without --carry; run: $(_contribute_upgrade_command)"
  [[ -z $(_contribute_get carry) ]] || carry=1
  contribute_is_clone "$CT_CLONE" || die "the clone $CT_CLONE of run $id is missing"
  if ((main)); then
    # K4: the instance may follow the main commit that this run's check and
    # trial passed for (publish verified that main has its tree).
    [[ -n $merged ]] || die "run $id has no merged commit; run: dotsteward contribute publish"
    [[ -n $CT_TEST_SHA && $(_contribute_get trial_sha) == "$CT_TEST_SHA" ]] ||
      die "the trial of run $id did not pass for its checked commit; the instance follows only a commit that passed check and trial"
    git -C "$CT_CLONE" cat-file -e "$merged^{commit}" 2>/dev/null || contribute_fetch_main "$CT_CLONE" origin
    [[ $(git -C "$CT_CLONE" rev-parse --verify --quiet "$merged^{tree}") == "$CT_TESTED_TREE" ]] ||
      die "the merged commit ${merged:0:12} does not have the tested tree ${CT_TESTED_TREE:0:12}; the instance follows only a commit that passed check and trial"
    commit=$merged
    kind=rev
    rev=$merged
    label="main@${merged:0:12}"
    version=$label
  else
    [[ $CT_STEP == upgrade && -n $tag ]] ||
      die "run $id is not released; run: dotsteward contribute release (a release commit), or follow its merged commit with: dotsteward contribute upgrade --main"
    [[ -n $merged ]] || die "run $id has no release tag; run: dotsteward contribute release"
    [[ -z $tag_option || $tag_option == "$tag" ]] || die "--tag $tag_option is not the release of run $id ($tag)"
    commit=$(git -C "$CT_CLONE" rev-parse --verify --quiet "refs/tags/$tag^{commit}") ||
      die "the tag $tag is missing in $CT_CLONE"
    [[ $commit == "$merged" ]] || die "the tag $tag points at ${commit:0:12}, not at the merged commit ${merged:0:12}"
    kind=tag
    rev=$tag
    label=$tag
    version=${tag#v}
  fi
  contribute_is_clone "$DS_INSTANCE_ROOT" || die "the instance $DS_INSTANCE_ROOT is not the top of a git clone"

  local profile fork="" base head instance_commit upgrade_commit subject upgrade=full
  ((build_only == 0)) || upgrade=build-only
  profile=$(_contribute_profile)
  if [[ $CT_RUN_MODE == fork ]]; then
    _contribute_remote_facts
    fork=$CT_FORK_SLUG
  fi
  instance_commit=$(_contribute_get instance_commit)
  upgrade_commit=$(_contribute_get upgrade_commit)
  base=$(_contribute_get instance_base)
  if [[ -z $instance_commit && -z $upgrade_commit ]]; then
    head=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
    if [[ -z $base ]]; then
      ! _contribute_instance_dirty ||
        die "the instance $DS_INSTANCE_ROOT has uncommitted changes; commit or remove them before the upgrade"
      _contribute_carry_prepare "$carry"
      [[ -n $(_contribute_get carry) ]] || carry=0
      # shellcheck disable=SC2016 # jq variables
      _contribute_set '.upgrade_to = $to' --arg to "$(if ((main)); then printf main; else printf '%s' "$tag"; fi)"
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
    _contribute_set_framework_url "$kind" "$(if [[ $kind == tag ]]; then printf '%s' "$tag"; else printf '%s' "$merged"; fi)" "$fork"
    log "nix flake update dotsteward"
    nix_cmd flake update dotsteward --flake "$DS_INSTANCE_ROOT" </dev/null ||
      _contribute_red "upgrade: nix flake update dotsteward failed; the changes stay uncommitted, run upgrade again"
    _contribute_verify_lock "$kind" "$(if [[ $kind == tag ]]; then printf '%s' "$tag"; else printf '%s' "$merged"; fi)" "$commit" "$label"
    _contribute_refresh_template "$rev" "$label"
    _contribute_pinned sync ||
      _contribute_red "upgrade: dotsteward sync failed; the changes stay uncommitted, run upgrade again"
    git -C "$DS_INSTANCE_ROOT" add -A
    _contribute_pinned gate --scope maintain ||
      _contribute_red "upgrade: the gate failed on the upgraded instance; the changes stay uncommitted (staged), nothing is published"
    if git -C "$DS_INSTANCE_ROOT" diff --cached --quiet; then
      log "the instance already uses $label"
    else
      subject=${DS_COMMIT_UPGRADE_SUBJECT//\{version\}/$version}
      git -C "$DS_INSTANCE_ROOT" commit --quiet -m "$subject" </dev/null ||
        _contribute_red "upgrade: git commit failed in the instance"
      log "committed: $subject"
    fi
    upgrade_commit=$(git -C "$DS_INSTANCE_ROOT" rev-parse HEAD)
    # shellcheck disable=SC2016 # jq variables
    _contribute_set '.upgrade_commit = $commit' --arg commit "$upgrade_commit"
  fi
  if [[ -z $instance_commit ]]; then
    if ((carry)); then
      _contribute_carry_apply "$upgrade_commit"
      _contribute_carry_finish
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
    log "nothing to publish: the instance's published commit ${base:0:12} already uses $label"
  else
    _contribute_pinned update publish --scope maintain --expected-base "$base" ||
      _contribute_red "upgrade: update publish failed; run upgrade again once it is fixed"
  fi
  if [[ -n $(_contribute_get carry) ]]; then
    git -C "$DS_INSTANCE_ROOT" update-ref -d "$(_contribute_carry_ref)" 2>/dev/null || true
  fi
  if ((build_only)) && [[ $(_contribute_get trial_switched) == true ]]; then
    warn "the live generation still uses the trial framework (a build-only upgrade does not switch); switch to the upgraded instance with: dotsteward rebuild --profile $profile --switch"
  fi
  # shellcheck disable=SC2016 # jq variables
  _contribute_set '.upgrade = $kind | .step = "report"' --arg kind "$upgrade"
  log "upgraded the instance to $label (${instance_commit:0:12}, $upgrade)"
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
  local carried
  carried=$(contribute_state_read "$CT_RUN_ID" | jq -r 'if .carry and .instance_commit == null then .carry.head else empty end')
  if [[ -n $carried ]]; then
    log "the instance commits carried across the upgrade stay saved as $(_contribute_carry_ref) (${carried:0:12}); get them back with: git -C $DS_INSTANCE_ROOT reset --hard ${carried:0:12}"
  fi
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
    release)
      # Release trains: a run may end once it is published; a later release
      # bundles it. After a trial switch the machine first returns to the
      # instance's pinned framework, as abort does. An upgrade that started
      # (upgrade --main) left instance changes or commits behind: it is
      # finished or aborted, never ended as a mere publish.
      [[ -z $(_contribute_get instance_base) && -z $(_contribute_get carry) ]] ||
        die "the upgrade of run $id has started, so the run no longer ends at publish; finish it with: $(_contribute_upgrade_command), or end the run with: dotsteward contribute abort"
      _contribute_recover || die "report stopped: the recovery did not finish; run report again once the problem is fixed"
      _contribute_set '.step = "done" | .outcome = "published"'
      ;;
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
      trial_switched, recovery: (.recovery // null), promote: (.promote // null)}')
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
    "  recovery after the trial switch: \(.recovery | show)",
    (if .promote then "  promoted component: \(.promote) (exempt from the instance-leak scan of this run)" else empty end)' <<<"$document"
}
