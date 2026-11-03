#!/usr/bin/env bash
# summary: Change the dotsteward framework itself: mode, setup, start, commit, check, trial, publish, release, upgrade
# Usage: dotsteward [--instance DIR] contribute <step> [OPTION...]
#        dotsteward contribute --help
#
# Runs one step of a framework contribution from this machine:
# reproduce, fix generically, test here, then publish to the upstream
# (owner mode) or to the user's fork (fork mode) and upgrade the instance.
# The framework upstream is the dotsteward input of the instance flake.lock;
# [upstream] in workstation.toml chooses the mode, the fork and the local
# clone. The dotsteward-contribute skill drives the steps in order.
#
# Steps:
#   mode [--json]           owner or fork, and why: owner needs
#                           upstream.contribute = "owner", a gh login, push
#                           permission on the upstream and a local clone
#                           whose origin is the upstream (or no clone yet);
#                           otherwise fork mode, with a warning (never an
#                           error). --json: {schema_version, mode,
#                           configured, fallback, upstream, upstream_url,
#                           upstream_remote, fork, fork_url, clone,
#                           gh_login}. Writes nothing.
#   setup [--create-fork]   clones upstream.local_clone (owner: the
#                           upstream; fork: the fork, plus an `upstream`
#                           remote) or fetches an existing clone, and sets
#                           its user.name and user.email (the GitHub login
#                           and noreply address) and core.hooksPath
#                           (.githooks: the clone's pre-commit, commit-msg
#                           and pre-push hooks). A missing fork is created
#                           with `gh repo fork --clone=false` only with
#                           --create-fork (or DOTSTEWARD_ASSUME_YES=1).
#                           Owner mode refuses without the denylist; fork
#                           mode warns.
#   start --slug SLUG [--promote NAME]
#                           branch fix/SLUG from a freshly fetched upstream
#                           main and a new run (the current one); the same
#                           SLUG again resumes its unfinished run. --promote:
#                           the run moves the private component NAME (source
#                           "instance") into the catalog, with the user's
#                           explicit approval; recorded as promote, it
#                           exempts exactly the term NAME from the
#                           instance-leak scan of the run's check (the same
#                           SLUG again sets it on the unfinished run;
#                           another NAME is refused)
#   commit -m SUBJECT [-m PARAGRAPH...] [--test]
#                           in the run's clone: stages everything (git add
#                           -A) and commits with the clone's identity (from
#                           setup) and UTC dates, whatever the environment
#                           says. SUBJECT is a conventional commit subject
#                           (TYPE(AREA): text, TYPE from
#                           commit.conventional_types of `dotsteward
#                           context --json`); further -m options are the
#                           paragraphs of the body; trailers and attribution
#                           lines (Co-Authored-By, Signed-off-by,
#                           Claude-Session) are refused, as the clone's
#                           commit-msg and pre-commit hooks refuse them and
#                           non-UTC dates for a plain git commit. --test: the
#                           reproduction test (a test subject). Refused
#                           before the reproduction failed and after
#                           publish; a commit after a passing check sends
#                           the run back to check
#   check [--expect-fail PATH]
#                           with --expect-fail: runs `tests/run.sh PATH` in
#                           the clone, which must fail (the reproduction).
#                           Without it, the framework gate on a clean clone
#                           at the run's branch: the privacy scans (tree;
#                           commits after upstream main with metadata rules
#                           and the denylist; the instance-leak scan with
#                           terms from `dotsteward context --json`), then
#                           `nix flake check` with the framework check's own
#                           parallelism (derived from the machine, at most 4
#                           jobs; DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS and
#                           DOTSTEWARD_CONTRIBUTE_NIX_CORES override it).
#                           Records test_sha and tested_tree on success; any
#                           failure before publish withdraws an earlier pass
#                           (the run goes back to check); a privacy stop or
#                           a failed nix flake check after a trial switch
#                           also runs the recovery (see abort). A branch that
#                           changes privacy/allowlist.txt or
#                           privacy/policy.toml is a privacy hard stop: they
#                           change only in their own, manually reviewed
#                           pull request; the leak terms skip only the
#                           allowlist of upstream main. A branch without
#                           commits after upstream main is refused, except
#                           after a tree mismatch
#   trial [--build-only]    the trial on this machine: gate,
#                           rebuild --switch and e2e of the instance with
#                           --framework-override git+file://<clone>?rev=<the
#                           checked commit>; --build-only: gate and rebuild
#                           --build-only (no switch, no e2e). Red: nothing is
#                           published and a trial switch is recovered. An
#                           instance HEAD ahead of origin (commits that wait
#                           for the fix): e2e, and the recovery's, checks
#                           the remote against origin's commit
#                           (--expected-remote-base)
#   publish [--pr-to-upstream]
#                           owner: push fix/SLUG, open (or reuse) the pull
#                           request, wait for its lint and privacy checks
#                           only (lint of ci.yml, generic of privacy.yml;
#                           the full check runs on main after the merge; a
#                           build-only trial also needs clean-install.yml
#                           green on the commit, dispatched on the branch
#                           when missing),
#                           merge by fast-forwarding main to the checked
#                           commit (never a merge made by GitHub) and
#                           verify the merged tree is the tested tree; fork:
#                           push, the fork's CI, fast-forward the fork's
#                           main, an upstream pull request only with
#                           upstream.pr_to_upstream or --pr-to-upstream.
#                           VERSION of the checked commit must be the
#                           release its commits are based on (the run
#                           releases nothing: release trains) or exactly the
#                           next release (a release commit, tools/version.sh
#                           bump), before anything is pushed and again
#                           before the merge. Upstream main moved: the
#                           branch is rebased and the run goes back to check
#                           (exit 5); so does a tree mismatch after the
#                           merge, with the branch on the merged main
#   release [--major]       the release that VERSION of the merged commit
#                           names, when it is the next one: after the newest
#                           v* tag, as the conventional commits since the
#                           release they are based on decide (any feat: the
#                           next minor, else the next patch; from 0.0.0
#                           without a tag; a breaking change: the next
#                           major, cut only with --major). Nothing pending
#                           (VERSION still the base release) is refused:
#                           report ends the run at publish. An annotated
#                           tag on the merged commit, pushed once main's CI
#                           (ci.yml with the full check, privacy.yml) is
#                           green on that commit, waited for as publish
#                           waits; owner: gh release create --notes-file
#                           (the commits since the previous release under
#                           Features, Fixes and Other) --verify-tag. A
#                           release tag already on the merged commit (cut by
#                           release.yml first) is recorded as the run's
#                           release once main's CI is green, its GitHub
#                           release created when missing
#   upgrade [--tag TAG | --main] [--carry] [--build-only]
#                           the instance to the release: update prepare
#                           --scope maintain, the dotsteward input of
#                           flake.nix, nix flake update dotsteward,
#                           bootstrap.sh and .dotsteward/cli.sh from the
#                           release's template/, sync, gate, a commit with
#                           commit.upgrade_subject ({version}: TAG without
#                           v), rebuild --switch and e2e (--build-only:
#                           rebuild --build-only), update publish --scope
#                           maintain; re-runnable. --main (right after
#                           publish too): the merged commit instead, the
#                           one check and trial passed for, pinned by its
#                           revision on the same repository URL
#                           ({version}: main@<12-digit commit>). An instance
#                           whose HEAD has commits that origin lacks is
#                           refused; --carry saves them, resets the instance
#                           to origin, upgrades, applies them again on top
#                           (a conflict outside the generated mirrors stops
#                           with the cherry-pick in progress: resolve it,
#                           git cherry-pick --continue, then upgrade again),
#                           syncs and gates the whole tree, and publishes
#                           them with the upgrade
#   abort                   ends the run; after a trial switch it first runs
#                           the recovery: rebuild --switch and e2e without
#                           an override, back to the pinned framework
#   report [--json]         the run's result (pull request, merged commit,
#                           release, instance commit, tests, the promoted
#                           component); ends the run, also at step release
#                           (a run that ends at publish), after the recovery
#                           of a trial switch
#   status [--json] [--wait [--timeout SECONDS]]
#                           the run's state and its running step (--json: the
#                           state document); once merged_sha is set also
#                           main_ci, main's CI for the merged commit read
#                           now: {sha, state (pending, green, red or
#                           unknown), url, runs}. --wait: first waits until
#                           no step of the run runs (at most SECONDS), then
#                           exits with the status of the run's last step (0,
#                           1, 4 or 5; 1 for an interrupted step or an
#                           unknown outcome; 0 before the first step), or 3
#                           when SECONDS passed first
# Options of the steps that use a run (commit, check, status, remote steps):
#   --id ID                 that run instead of the current one
#
# Running steps: check, trial, publish, release, upgrade, abort and report
# record running = {step, pid, started_at} in the run's state while they
# work and replace it with last_step = {step, status, started_at, ended_at}
# when they end, also after a failure and on SIGINT, SIGTERM or SIGHUP.
# While a step of any run is running, setup, start, commit and those steps
# refuse and name it. A marker whose process is gone (killed, or the machine
# stopped) is stale: status and the next step report and clear it, and its
# outcome is unknown (last_step.status null).
#
# State: one file per run, <state root>/contribute/<id>.json (0600, in a 0700
# directory), id = <UTC timestamp>-<slug>, with the fields id, slug, mode,
# clone, branch, base_sha, test_sha, tested_tree, trial_switched, pr,
# merged_sha, tag, instance_commit and step, plus profile, trial, trial_sha,
# upgrade, upgrade_to, instance_base, upgrade_commit, carry, recovery and
# outcome from the remote steps (see cli/lib/contribute-remote.sh), running
# and last_step (see Running steps) and promote (start --promote, only when
# given); <state root>/contribute/current holds the current run's id. step
# is the next step of the run: reproduce, fix, check, trial, publish,
# release, upgrade, report or done; every step reads and updates the file,
# so an interrupted run resumes at step.
#
# Privacy: the denylist is ~/.config/dotsteward/denylist.txt, the file the
# pre-push hook reads; check needs it in both modes. Findings are always
# redacted. Instance-leak terms are skipped when they are shorter than 4
# characters, equal to a line of the clone's privacy/allowlist.txt (the
# scanner masks those strings), part of the contributor's public identity
# (the clone's user.name and user.email, carried by every commit) or already
# in the content of the fetched upstream main outside the allowlisted
# strings (published before, so no new leak); the run's promote (start
# --promote) is exempt as well, as the one term the run exists to publish,
# never through privacy/allowlist.txt or privacy/policy.toml. Any finding (or
# scan failure) is a hard stop: exit 4, nothing may be published.
#
# Exit status:
#   0  done
#   1  refused or failed
#   3  still running (status --wait --timeout): the step has not ended yet;
#      wait again
#   4  privacy hard stop (check): nothing may be published
#   5  back to check (publish): upstream main moved, the branch was rebased
#      (or must be rebased by hand after a conflict)
set -Eeuo pipefail

lib_dir=${DOTSTEWARD_LIB:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)}
framework_root=${DOTSTEWARD_FRAMEWORK_ROOT:-$(cd -P -- "$lib_dir/../.." && pwd)}

# shellcheck source=cli/lib/lib.sh
source "$lib_dir/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$lib_dir/config.sh"
# shellcheck source=cli/lib/commit-rules.sh
source "$lib_dir/commit-rules.sh"

# The exit status of a privacy hard stop.
CONTRIBUTE_PRIVACY_STOP=4
# The private denylist, as the pre-push hook reads it.
# shellcheck disable=SC2088 # shown to the user as written, never expanded
CONTRIBUTE_DENYLIST_SHOWN='~/.config/dotsteward/denylist.txt'
# The steps of a run, in order (the values of the state's step field).
CONTRIBUTE_RUN_STEPS=(reproduce fix check trial publish release upgrade report 'done')
# The long steps: they record a running marker in their run while they work
# (report too: at step release it first runs the recovery of a trial
# switch).
CONTRIBUTE_LONG_STEPS=(check trial publish release upgrade abort report)
# The steps that change the clone, a run or the machine: they refuse while a
# step of any run is running (all runs share the clone and the machine).
CONTRIBUTE_BUSY_STEPS=(setup start commit check trial publish release upgrade abort report)
# The exit status of `status --wait --timeout` while the step still runs.
CONTRIBUTE_STILL_RUNNING=3

usage() {
  sed -n '3,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

# need_value FLAG ARGC VALUE: fails unless an option that takes a value got one.
need_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    die "$1 requires a value"
  fi
}

contribute_denylist_path() {
  printf '%s\n' "$HOME/.config/dotsteward/denylist.txt"
}

# contribute_denylist_ready: the denylist is a readable file with at least
# one entry (a line that is neither blank nor a comment).
contribute_denylist_ready() {
  local file
  file=$(contribute_denylist_path)
  [[ -f $file && -r $file ]] || return 1
  grep -qvE '^[[:space:]]*(#|$)' "$file"
}

# contribute_load_config: the instance configuration (--instance or
# discovery), loaded once per command.
contribute_load_config() {
  [[ -z ${CT_CONFIG_LOADED:-} ]] || return 0
  # shellcheck disable=SC2119 # config_load takes no argument here
  config_load
  CT_CONFIG_LOADED=1
}

# --- run state ----------------------------------------------------------------------

contribute_runs_dir() {
  printf '%s/contribute\n' "$(state_root)"
}

contribute_valid_id() {
  [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[a-z0-9][a-z0-9-]*$ ]]
}

contribute_state_file() {
  printf '%s/%s.json\n' "$(contribute_runs_dir)" "$1"
}

# contribute_run_id [ID]: ID (validated, its state file must exist) or the
# current run's id.
contribute_run_id() {
  local id=${1:-} pointer
  if [[ -z $id ]]; then
    pointer=$(contribute_runs_dir)/current
    [[ -f $pointer ]] || die "no contribute run; start one with: dotsteward contribute start --slug SLUG"
    id=$(<"$pointer")
    contribute_valid_id "$id" || die "the current run pointer $pointer is damaged"
  else
    contribute_valid_id "$id" || die "invalid run id: $id"
  fi
  [[ -f $(contribute_state_file "$id") ]] || die "no contribute run with id $id"
  printf '%s\n' "$id"
}

# contribute_state_read ID: the run's state document (compact JSON).
contribute_state_read() {
  local file document
  file=$(contribute_state_file "$1")
  document=$(jq -c 'if type == "object" then . else error("not an object") end' "$file" 2>/dev/null) ||
    die "the state file of run $1 is not a JSON object: $file"
  printf '%s\n' "$document"
}

# contribute_state_get ID FIELD: one field, raw (null prints as null).
contribute_state_get() {
  contribute_state_read "$1" | jq -r --arg field "$2" '.[$field] | if . == null then "null" else . end'
}

# contribute_state_write ID JSON: replaces the state file atomically (0600).
contribute_state_write() {
  local id=$1 json=$2 dir file tmp
  dir=$(contribute_runs_dir)
  ensure_private_dir "$dir"
  file=$(contribute_state_file "$id")
  tmp=$(mktemp "$dir/.$id.XXXXXX")
  if ! jq --indent 2 . <<<"$json" >"$tmp"; then
    rm -f -- "$tmp"
    die "cannot write the state of run $id"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$file"
}

# contribute_state_update ID JQ_FILTER [JQ_OPTION...]: applies the filter to
# the state document and writes it back.
contribute_state_update() {
  local id=$1 filter=$2 json
  shift 2
  json=$(contribute_state_read "$id" | jq -c "$@" "$filter") || die "cannot update the state of run $id"
  contribute_state_write "$id" "$json"
}

# contribute_set_current ID: makes ID the current run.
contribute_set_current() {
  local dir tmp
  dir=$(contribute_runs_dir)
  ensure_private_dir "$dir"
  tmp=$(mktemp "$dir/.current.XXXXXX")
  printf '%s\n' "$1" >"$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$dir/current"
}

# contribute_step_index STEP: the position of STEP in CONTRIBUTE_RUN_STEPS.
contribute_step_index() {
  local i
  for i in "${!CONTRIBUTE_RUN_STEPS[@]}"; do
    if [[ ${CONTRIBUTE_RUN_STEPS[i]} == "$1" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

# --- running steps ------------------------------------------------------------------

# Cleanups registered by the steps (contribute_at_exit), and the run whose
# running marker this process holds.
CONTRIBUTE_AT_EXIT=()
CONTRIBUTE_CLAIMED=""

# contribute_at_exit COMMAND: COMMAND (a string, evaluated like a trap) runs
# when the command exits, before the running marker is released. Steps
# register their cleanups here: an EXIT trap of their own would replace the
# dispatcher's, and with it the release of the marker.
contribute_at_exit() {
  CONTRIBUTE_AT_EXIT+=("$1")
}

# _contribute_on_exit: the EXIT trap. The registered cleanups (last first),
# then the release of the running marker; the exit status stays.
_contribute_on_exit() {
  local status=$? i
  for ((i = ${#CONTRIBUTE_AT_EXIT[@]} - 1; i >= 0; i--)); do
    eval "${CONTRIBUTE_AT_EXIT[i]}" || true
  done
  if [[ -n $CONTRIBUTE_CLAIMED ]]; then
    (_contribute_release "$CONTRIBUTE_CLAIMED" "$status") || true
  fi
  exit "$status"
}

_contribute_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _contribute_listed WORD LIST...: WORD is one of LIST.
_contribute_listed() {
  local word=$1 item
  shift
  for item in "$@"; do
    [[ $item != "$word" ]] || return 0
  done
  return 1
}

# _contribute_pid_alive PID: PID is a running contribute command other than
# this one. A process with another command line (from /proc, else ps) took
# over the number of a step that ended without releasing its marker; a
# zombie has no command line. When ps cannot answer either, kill -0 decides
# alone.
_contribute_pid_alive() {
  local pid=$1 command
  [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] && ((pid != $$)) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -e /proc/$pid/cmdline ]]; then
    command=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  else
    command=$(ps -o command= -p "$pid" 2>/dev/null) || return 0
  fi
  [[ $command == *contribute* ]]
}

# _contribute_marker_of ID: "STEP<TAB>PID<TAB>STARTED_AT" of the running marker
# in the state of run ID, live or stale; nothing without one.
_contribute_marker_of() {
  local file
  file=$(contribute_state_file "$1")
  grep -qF '"running":' "$file" 2>/dev/null || return 0
  jq -r '.running | select(type == "object") | [.step, .pid, .started_at] | map(tostring) | @tsv' \
    "$file" 2>/dev/null || true
}

# _contribute_clear_stale ID STEP PID STARTED_AT: replaces the stale marker
# of run ID by a last_step with an unknown outcome, with a warning.
_contribute_clear_stale() {
  local id=$1 step=$2 pid=$3 started=$4
  # shellcheck disable=SC2016 # jq variables
  contribute_state_update "$id" 'if (.running | type) == "object" and (.running.pid | tostring) == $pid then
      .last_step = {step: .running.step, status: null, started_at: .running.started_at, ended_at: null}
      | del(.running)
    else . end' --arg pid "$pid"
  warn "the $step of run $id (pid $pid, since $started) ended without clearing its running marker; the marker is cleared and the outcome of that $step is unknown"
}

# _contribute_live_marker [ID]: "ID<TAB>STEP<TAB>PID<TAB>STARTED_AT" of the live
# running marker of run ID, else of the first run with one; stale markers
# met on the way are cleared. Runs with the lock of the runs directory held.
_contribute_live_marker() {
  local only=${1:-} dir file id marker step pid started
  dir=$(contribute_runs_dir)
  for file in "$dir"/*.json; do
    [[ -f $file ]] || continue
    id=$(basename -- "$file" .json)
    contribute_valid_id "$id" || continue
    [[ -z $only || $id == "$only" ]] || continue
    marker=$(_contribute_marker_of "$id")
    [[ -n $marker ]] || continue
    IFS=$'\t' read -r step pid started <<<"$marker"
    if _contribute_pid_alive "$pid"; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$step" "$pid" "$started"
      return 0
    fi
    _contribute_clear_stale "$id" "$step" "$pid" "$started"
  done
}

# _contribute_locked COMMAND [ARG...]: COMMAND with the lock of the runs
# directory (<runs>/.lock) held, released before it returns, so no child
# process of a step ever holds it.
_contribute_locked() {
  local dir lock fd
  dir=$(contribute_runs_dir)
  lock=$dir/.lock
  require_command flock
  (umask 077 && : >>"$lock") || die "cannot create the lock file $lock"
  exec {fd}>>"$lock"
  flock -w 60 "$fd" || die "another contribute command holds $lock"
  "$@"
  exec {fd}>&-
}

# _contribute_claim STEP [ID]: refuses while a step of any run is running;
# with ID, records the running marker of STEP for this process in run ID
# (released by the EXIT trap). Runs with the lock held.
_contribute_claim() {
  local step=$1 id=${2:-} busy rid rstep rpid rstarted
  busy=$(_contribute_live_marker)
  if [[ -n $busy ]]; then
    IFS=$'\t' read -r rid rstep rpid rstarted <<<"$busy"
    die "$rstep is running for run $rid since $rstarted (pid $rpid); wait for it with: dotsteward contribute status --wait"
  fi
  [[ -n $id ]] || return 0
  # shellcheck disable=SC2016 # jq variables
  contribute_state_update "$id" '.running = {step: $step, pid: $pid, started_at: $now}' \
    --arg step "$step" --argjson pid "$$" --arg now "$(_contribute_now)"
  CONTRIBUTE_CLAIMED=$id
}

# _contribute_release ID STATUS: the running marker of this process in run
# ID becomes last_step with STATUS.
_contribute_release() {
  local id=$1 status=$2
  [[ -f $(contribute_state_file "$id") ]] || return 0
  # shellcheck disable=SC2016 # jq variables
  contribute_state_update "$id" 'if (.running | type) == "object" and .running.pid == $pid then
      .last_step = {step: .running.step, status: $status, started_at: .running.started_at, ended_at: $now}
      | del(.running)
    else . end' --argjson pid "$$" --argjson status "$status" --arg now "$(_contribute_now)"
}

# _contribute_quiet_run_id ARG...: the run that the arguments of a step
# address (--id ID, else the current run); status 1 without a message when
# there is none, so that the step reports the problem itself.
_contribute_quiet_run_id() {
  local id=""
  while (($#)); do
    if [[ $1 == --id ]]; then
      (($# >= 2)) && [[ -n $2 ]] || return 1
      id=$2
      shift
    fi
    shift
  done
  (contribute_run_id "$id") 2>/dev/null
}

# _contribute_run_marker ID: the live running marker of run ID, as
# _contribute_live_marker prints it; a stale one is cleared (with the lock).
_contribute_run_marker() {
  local id=$1 marker step pid started
  marker=$(_contribute_marker_of "$id")
  [[ -n $marker ]] || return 0
  IFS=$'\t' read -r step pid started <<<"$marker"
  if _contribute_pid_alive "$pid"; then
    printf '%s\t%s\t%s\t%s\n' "$id" "$step" "$pid" "$started"
    return 0
  fi
  _contribute_locked _contribute_live_marker "$id"
}

# _contribute_last_status ID: the exit status of `status --wait`: the status
# of the run's last step when the usage documents it (0, 1, 4 or 5), 1 for
# any other one and for an unknown outcome, 0 before the first step.
_contribute_last_status() {
  local status
  status=$(contribute_state_read "$1" | jq -r 'if has("last_step") then (.last_step.status // "unknown" | tostring) else "0" end')
  case $status in
    0 | 1 | 4 | 5) printf '%s\n' "$status" ;;
    *) printf '1\n' ;;
  esac
}

# --- status -------------------------------------------------------------------------

# _contribute_print_status ID JSON MARKER: the state of run ID (JSON 1: the
# document), with MARKER (from _contribute_run_marker) as its running step.
_contribute_print_status() {
  local id=$1 json=$2 marker=$3 document step pid started
  document=$(contribute_state_read "$id")
  # Once the run has a merged commit: main's CI for it, read now
  # (cli/lib/contribute-remote.sh).
  if [[ -n $(jq -r '.merged_sha // empty' <<<"$document") ]] && declare -F contribute_main_ci_json >/dev/null; then
    document=$(jq -c --argjson ci "$(contribute_main_ci_json "$id")" '. + {main_ci: $ci}' <<<"$document")
  fi
  if ((json)); then
    jq --indent 2 . <<<"$document"
    return 0
  fi
  log "contribute run $id"
  if [[ -n $marker ]]; then
    IFS=$'\t' read -r _ step pid started <<<"$marker"
    log "$step running since $started (pid $pid)"
  fi
  jq -r 'to_entries[] | select(.key != "id" and .key != "running")
    | if .key == "last_step" and (.value | type) == "object" then
        .value as $last
        | "  last_step: \($last.step) "
          + (if $last.status == null then "ended without recording its outcome" else "exited \($last.status)" end)
          + " (started \($last.started_at // "at an unknown time")"
          + (if $last.ended_at then ", ended \($last.ended_at))" else ")" end)
      elif .key == "main_ci" then
        "  main_ci: \(.value.state)\(if .value.url then " \(.value.url)" else "" end)\(if .value.reason then " (\(.value.reason))" else "" end)"
      else "  \(.key): \(.value | if type == "string" then . else tojson end)" end' <<<"$document"
}

contribute_cmd_status() {
  local json=0 id="" wait=0 timeout=""
  while (($#)); do
    case $1 in
      --json) json=1 ;;
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      --wait) wait=1 ;;
      --timeout)
        need_value "$1" "$#" "${2:-}"
        timeout=$2
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
  [[ -z $timeout || $timeout =~ ^[1-9][0-9]{0,8}$ ]] || die "--timeout must be a positive number of seconds"
  [[ -z $timeout ]] || ((wait)) || die "--timeout needs --wait"
  contribute_load_config
  id=$(contribute_run_id "$id")
  local marker step pid started timed_out=0
  marker=$(_contribute_run_marker "$id")
  if ((wait)) && [[ -n $marker ]]; then
    IFS=$'\t' read -r _ step pid started <<<"$marker"
    ((json)) || log "waiting for the $step of run $id (pid $pid, started $started)"
    SECONDS=0
    while [[ -n $marker ]]; do
      if [[ -n $timeout ]] && ((SECONDS >= timeout)); then
        timed_out=1
        break
      fi
      sleep 1
      marker=$(_contribute_run_marker "$id")
    done
  fi
  _contribute_print_status "$id" "$json" "$marker"
  ((wait)) || return 0
  if ((timed_out)); then
    warn "$step is still running after $timeout s; wait again with: dotsteward contribute status --wait"
    exit "$CONTRIBUTE_STILL_RUNNING"
  fi
  exit "$(_contribute_last_status "$id")"
}

# --- dispatch -----------------------------------------------------------------------

# shellcheck source=cli/lib/contribute-local.sh
source "$lib_dir/contribute-local.sh"
if [[ -f $lib_dir/contribute-remote.sh ]]; then
  # shellcheck source=/dev/null
  source "$lib_dir/contribute-remote.sh"
fi

(($#)) || {
  usage >&2
  die "missing step; see dotsteward contribute --help"
}
step=$1
shift
case $step in
  -h | --help)
    usage
    exit 0
    ;;
  mode | setup | start | commit | check | status | trial | publish | release | upgrade | abort | report) ;;
  *) die "unknown contribute step: $step" ;;
esac
handler=contribute_cmd_$step
declare -F "$handler" >/dev/null || die "contribute $step is not available in this framework version"

# Signals end the command through exit, so the EXIT trap releases the
# running marker.
trap _contribute_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
help=0
for arg in "$@"; do
  [[ $arg != -h && $arg != --help ]] || help=1
done
if ((!help)) && _contribute_listed "$step" "${CONTRIBUTE_BUSY_STEPS[@]}"; then
  contribute_load_config
  if [[ -d $(contribute_runs_dir) ]]; then
    claim=""
    if _contribute_listed "$step" "${CONTRIBUTE_LONG_STEPS[@]}"; then
      claim=$(_contribute_quiet_run_id "$@") || claim=""
    fi
    _contribute_locked _contribute_claim "$step" "$claim"
  fi
fi
"$handler" "$@"
