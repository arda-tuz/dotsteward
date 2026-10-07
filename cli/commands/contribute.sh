#!/usr/bin/env bash
# summary: Change the dotsteward framework itself: mode, setup, start, check, trial, publish, release, upgrade
# Usage: dotsteward [--instance DIR] contribute <step> [OPTION...]
#        dotsteward contribute --help
#
# Runs one step of a framework contribution from this machine (SPEC 9.4):
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
#                           and noreply address) and core.hooksPath. A
#                           missing fork is created with `gh repo fork
#                           --clone=false` only with --create-fork (or
#                           DOTSTEWARD_ASSUME_YES=1). Owner mode refuses
#                           without the denylist; fork mode warns.
#   start --slug SLUG       branch fix/SLUG from a freshly fetched upstream
#                           main and a new run (the current one); the same
#                           SLUG again resumes its unfinished run
#   check [--expect-fail PATH]
#                           with --expect-fail: runs `tests/run.sh PATH` in
#                           the clone, which must fail (the reproduction).
#                           Without it, the framework gate on a clean clone
#                           at the run's branch: the privacy scans (tree;
#                           commits after upstream main with metadata rules
#                           and the denylist; the instance-leak scan with
#                           terms from `dotsteward context --json`), then
#                           `nix flake check` with the gate's parallelism.
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
#   trial [--build-only]    the trial on this machine (SPEC 9.4 step 7): gate,
#                           rebuild --switch and e2e of the instance with
#                           --framework-override git+file://<clone>?rev=<the
#                           checked commit>; --build-only: gate and rebuild
#                           --build-only (no switch, no e2e). Red: nothing is
#                           published and a trial switch is recovered
#   publish [--pr-to-upstream]
#                           owner: push fix/SLUG, open (or reuse) the pull
#                           request, wait for its checks (a build-only trial
#                           also needs clean-install.yml green on the
#                           commit, dispatched on the branch when missing),
#                           merge by fast-forwarding main to the checked
#                           commit (never a merge made by GitHub) and
#                           verify the merged tree is the tested tree; fork:
#                           push, the fork's CI, fast-forward the fork's
#                           main, an upstream pull request only with
#                           upstream.pr_to_upstream or --pr-to-upstream.
#                           VERSION of the checked commit must equal the
#                           next release before anything is pushed and
#                           again before the merge. Upstream main moved: the
#                           branch is rebased and the run goes back to check
#                           (exit 5); so does a tree mismatch after the
#                           merge, with the branch on the merged main
#   release                 the next patch tag (newest v* tag + 1, v0.0.1
#                           without one; VERSION of the merged commit must
#                           equal it) as an annotated tag on the merged
#                           commit, pushed; owner: gh release create
#                           --generate-notes --verify-tag
#   upgrade [--tag TAG] [--build-only]
#                           the instance to the release: update prepare
#                           --scope maintain, the dotsteward input of
#                           flake.nix, nix flake update dotsteward,
#                           bootstrap.sh and .dotsteward/cli.sh from the
#                           release's template/, sync, gate, a commit with
#                           commit.upgrade_subject ({version}: TAG without
#                           v), rebuild --switch and e2e (--build-only:
#                           rebuild --build-only), update publish --scope
#                           maintain; re-runnable
#   abort                   ends the run; after a trial switch it first runs
#                           the recovery: rebuild --switch and e2e without
#                           an override, back to the pinned framework
#   report [--json]         the run's result (pull request, merged commit,
#                           release, instance commit, tests); ends the run
#   status [--json]         the run's state (--json: the state document)
# Options of the steps that use a run (check, status and the remote steps):
#   --id ID                 that run instead of the current one
#
# State: one file per run, <state root>/contribute/<id>.json (0600, in a 0700
# directory), id = <UTC timestamp>-<slug>, with the fields id, slug, mode,
# clone, branch, base_sha, test_sha, tested_tree, trial_switched, pr,
# merged_sha, tag, instance_commit and step, plus profile, trial, trial_sha,
# upgrade, instance_base, recovery and outcome from the remote steps (see
# cli/lib/contribute-remote.sh); <state root>/contribute/current
# holds the current run's id. step is the next step of the run: reproduce,
# fix, check, trial, publish, release, upgrade, report or done; every step
# reads and updates the file, so an interrupted run resumes at step.
#
# Privacy: the denylist is ~/.config/dotsteward/denylist.txt, the file the
# pre-push hook reads; check needs it in both modes. Findings are always
# redacted. Instance-leak terms are skipped when they are shorter than 4
# characters, equal to a line of the clone's privacy/allowlist.txt (the
# scanner masks those strings), part of the contributor's public identity
# (the clone's user.name and user.email, carried by every commit) or already
# in the content of the fetched upstream main outside the allowlisted
# strings (published before, so no new leak). Any finding (or scan failure)
# is a hard stop: exit 4, nothing may be published.
#
# Exit status:
#   0  done
#   1  refused or failed
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

# The exit status of a privacy hard stop.
CONTRIBUTE_PRIVACY_STOP=4
# The private denylist, as the pre-push hook reads it.
# shellcheck disable=SC2088 # shown to the user as written, never expanded
CONTRIBUTE_DENYLIST_SHOWN='~/.config/dotsteward/denylist.txt'
# The steps of a run, in order (the values of the state's step field).
CONTRIBUTE_RUN_STEPS=(reproduce fix check trial publish release upgrade report 'done')

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
# discovery).
contribute_load_config() {
  # shellcheck disable=SC2119 # config_load takes no argument here
  config_load
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

# --- status -------------------------------------------------------------------------

contribute_cmd_status() {
  local json=0 id=""
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
  local document
  document=$(contribute_state_read "$id")
  if ((json)); then
    jq --indent 2 . <<<"$document"
    return 0
  fi
  log "contribute run $id"
  jq -r 'to_entries[] | select(.key != "id")
    | "  \(.key): \(.value | if type == "string" then . else tojson end)"' <<<"$document"
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
  mode | setup | start | check | status | trial | publish | release | upgrade | abort | report) ;;
  *) die "unknown contribute step: $step" ;;
esac
handler=contribute_cmd_$step
declare -F "$handler" >/dev/null || die "contribute $step is not available in this framework version"
"$handler" "$@"
