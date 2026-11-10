#!/usr/bin/env bash
# summary: Verify this machine against the instance: the end-to-end checks of a profile
#
# The E2E runner. Checks, in run order, each with an id
# (<component>:<check-name> or core:<check-name>) that --list prints:
#    1. flags, configuration, profile, the Nix environment, the shape of
#       the manifest sections the checks read (a setup error finding on
#       the manifest file)
#    2. core:commands             the union of checks.commands of core and
#                                 the active components is on the user's
#                                 PATH (user_path)
#    3. <component>:<hook>        early checks.e2e hooks
#    4. core:managed-links        every managed link is a symlink that
#                                 resolves
#       <component>:agent-rules   every agent-rules target of the component
#                                 has the bytes of agent_rules.source
#       core:files                dotsteward.files: regular files; policy
#                                 always: the source bytes and the mode
#    5. core:agents               `dotsteward agents check`
#    6. core:settings-files       settings file entries and existing target
#                                 paths are regular non-symlink files
#       core:settings-verify      `dotsteward settings verify`
#    7. <component>:<hook>        main checks.e2e hooks
#    8. core:login-shell          the stable login shell path is executable,
#                                 listed in the shells file and the user's
#                                 login shell
#       core:apt-files            on Linux with dpkg (/var/lib/dpkg/status
#                                 below DOTSTEWARD_SYSTEM_ROOT): the pin
#                                 file of the gated classes has the
#                                 header and the pairs the apt engine
#                                 writes from what dpkg has now
#                                 (dotsteward_cli.apt_plan check-files);
#                                 another rule (after the owner's own
#                                 apt), a file the machine does not want,
#                                 one not there yet, or an engine that
#                                 cannot run, is a warning
#    9. core:repo-clean           the instance checkout is a clean git work
#                                 tree
#       core:repo-origin          origin equals instance.remote
#       core:repo-remote          origin <branch>, read with git_net, equals
#                                 HEAD, or HEAD is its ancestor: another machine
#                                 published, the check passes with a note. A
#                                 remote commit that is not here yet is fetched
#                                 without writing a ref, so concurrent runs and
#                                 fetches do not lock each other out. With
#                                 --expected-remote-base OID it equals OID and
#                                 OID is an ancestor of HEAD
#       core:repo-skill-count     the vendored SKILL.md files git tracks
#                                 match the number of skills lock entries
#   10. <component>:<hook>        late checks.e2e hooks
#   11. core:framework-skills     every <hm_root>/dotsteward-* link and every
#                                 framework skill of the manifest resolves to
#                                 the generation's framework source with the
#                                 digests of its skills/manifest.json
#   12. the success line
# Every run after the configuration loaded (not --list) records its result
# in <state root>/update/e2e.json (mode 0600, written atomically), keyed by
# the tree of the instance checkout's HEAD and the verified generation:
# schema_version "1.0", result (passed only when every check passed, so
# never for a run a signal ended), tree_oid and head_oid (null outside a
# git work tree), generation (null without one), profile,
# framework_override, repo_checks (false with --skip-repo-checks), findings
# (their number), root, recorded_at. `dotsteward txn publish` requires
# a passed record of an activated tree. --component NAME (repeatable) keeps
# only the checks whose id starts with NAME: (hooks of every phase, agent
# rules) of active components; such a run of some components records
# nothing, so it is never taken for a run of the machine (`dotsteward
# observe` checks the components a package change reached this way).
# Hooks run for the components active in the profile, in [components]
# order, then declaration order, when their profiles include the profile,
# with the hook environment and DOTSTEWARD_CHECK_ONLY=1. A check
# with nothing to verify is not listed and does not run: no commands, no
# managed links, no agent rules source or targets, no files, no settings
# buffer, no login shell; --skip-repo-checks drops step 9.
#
# Parallel hooks: consecutive hooks of one phase whose manifest entry says
# parallel: true run at the same time, at most --jobs N at a time (else
# DOTSTEWARD_E2E_JOBS, else 3); every other check, hook or not, runs alone
# after everything before it and before everything after it, so the phases
# stay barriers. A parallel hook runs in a session of its own (no
# controlling terminal, its own process group) with standard input from
# /dev/null; its standard output and error go to files of the run (one
# file when both streams of the run are the same file, which keeps their
# order) and its findings to a file of its own. Each hook is reported in
# plan order once it and every hook before it ended: its output, its
# findings, then its failure exactly as for a hook that runs alone, so the
# output, the findings, the exit status and the record are those of
# --jobs 1. Fail-fast: once a hook failed no further hook starts, and the
# report of the first failure ends the run. At the end of the run, also
# one a signal ended, the hooks still running get SIGTERM (their process
# groups; SIGKILL 10 seconds later) and are reaped before the record is
# written. With --jobs 1 every hook runs alone as before, in the
# foreground; parallel hooks need bash 5.1 or newer (with an older bash
# they run alone, with a warning) and python3, which starts the session.
#
# Findings are { step (the check id, or setup), path, code, message }.
# Without --keep-going the first finding ends the run; with it every check
# runs (a checkout that is not a git work tree skips the other repository
# checks). The agents check's findings keep their code and path; their
# message starts with the agents step; one an earlier check reported (same
# code and path) is not repeated. Codes:
#   missing-command; hook-failed; managed-link-missing,
#   managed-link-not-symlink, managed-link-broken; agent-rules-missing,
#   agent-rules-mismatch; file-missing, file-not-regular,
#   file-content-mismatch, file-mode-mismatch; source-missing,
#   source-unresolvable (a <store>/ path of the manifest mirror); the codes
#   of `dotsteward agents check`, agents-failed; settings-invalid,
#   settings-file-missing, settings-file-not-regular,
#   settings-not-converged, settings-error; login-shell-not-executable,
#   login-shell-not-listed, login-shell-mismatch; apt-file-mismatch;
#   repo-not-git, repo-dirty,
#   repo-origin-missing, repo-origin-mismatch, remote-unreachable,
#   remote-mismatch, remote-base-moved, base-not-ancestor,
#   skill-count-mismatch; framework-skill-unverifiable,
#   framework-skill-missing, framework-skill-not-link,
#   framework-skill-broken, framework-skill-not-in-generation,
#   framework-skill-foreign, framework-manifest-missing,
#   framework-skill-digest-mismatch; error (any other refusal), failed (a
#   check that exited without a finding).
set -Eeuo pipefail

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"
# shellcheck source=cli/lib/skills.sh
source "$DOTSTEWARD_LIB/skills.sh"
# shellcheck source=cli/lib/txn.sh
source "$DOTSTEWARD_LIB/txn.sh"
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward e2e --profile PROFILE [--expected-remote-base OID]
                      [--framework-override REF] [--generation PATH]
                      [--jobs N] [--keep-going] [--json] [--list]
                      [--skip-repo-checks] [--component NAME]...

Verifies that this machine matches the instance for PROFILE after a
rebuild: commands, component E2E hooks, managed links, agent rules, files,
the agents check, tracked settings, the login shell, the instance checkout
and its remote, and the framework skills of the generation.

  --profile PROFILE          a profile of the instance (required)
  --component NAME           only the checks of the active component NAME
                             (repeatable): its hooks and agent rules; such a
                             run writes no E2E record
  --expected-remote-base OID before a publish: the remote branch must still
                             be OID (40 hex digits) and OID an ancestor of
                             HEAD, instead of HEAD itself
  --framework-override REF   the framework flake reference the generation
                             was built with (also DOTSTEWARD_FRAMEWORK_OVERRIDE);
                             reported with the run
  --generation PATH          a built Home Manager generation: its manifest,
                             its framework skills and its home-path/bin
                             first on PATH; default: the active generation,
                             else the instance's manifest mirror
  --jobs N                   run at most N parallel hooks (parallel: true in
                             the manifest) at a time (default:
                             DOTSTEWARD_E2E_JOBS, else 3); 1 runs every hook
                             alone, in the foreground
  --keep-going               run every check and record each failure
  --json                     print { "result": "passed|failed", "findings":
                             [ { "step", "path", "code", "message" } ] } on
                             standard output (step is the check id); logs
                             go to standard error
  --list                     print the check ids of PROFILE in run order and
                             run nothing (with --json: { "profile", "checks" })
  --skip-repo-checks         skip the instance checkout and remote checks
                             (CI fixtures only)

Exit status: 0 every check passed (or --list), 1 a refusal or a failed
check.
EOF
}

profile=''
expected_base=''
framework_override=${DOTSTEWARD_FRAMEWORK_OVERRIDE:-}
generation=''
hook_jobs=${DOTSTEWARD_E2E_JOBS:-3}
hook_jobs_source=DOTSTEWARD_E2E_JOBS
keep_going=0
json=0
list=0
skip_repo=0
# The components of a run of some components (--component): such a run is no
# run of the machine and writes no record.
scope=()

# _e2e_value OPTION ARGC VALUE: a non-empty option value.
_e2e_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    die "e2e: $1 requires a value"
  fi
}

while (($#)); do
  case $1 in
    --profile | --expected-remote-base | --framework-override | --generation | --jobs | --component)
      _e2e_value "$1" "$#" "${2:-}"
      case $1 in
        --profile) profile=$2 ;;
        --component) scope+=("$2") ;;
        --expected-remote-base) expected_base=$2 ;;
        --framework-override) framework_override=$2 ;;
        --generation) generation=$2 ;;
        --jobs) hook_jobs=$2 hook_jobs_source=--jobs ;;
      esac
      shift 2
      ;;
    --profile=* | --expected-remote-base=* | --framework-override=* | --generation=* | --jobs=* | --component=*)
      _e2e_value "${1%%=*}" 2 "${1#*=}"
      case $1 in
        --profile=*) profile=${1#*=} ;;
        --component=*) scope+=("${1#*=}") ;;
        --expected-remote-base=*) expected_base=${1#*=} ;;
        --framework-override=*) framework_override=${1#*=} ;;
        --generation=*) generation=${1#*=} ;;
        --jobs=*) hook_jobs=${1#*=} hook_jobs_source=--jobs ;;
      esac
      shift
      ;;
    --keep-going) keep_going=1 && shift ;;
    --json) json=1 && shift ;;
    --list) list=1 && shift ;;
    --skip-repo-checks) skip_repo=1 && shift ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "e2e: unknown option: $1" ;;
    *) die "e2e: unexpected argument: $1" ;;
  esac
done
[[ -n $profile ]] || die "e2e: --profile is required"
[[ $hook_jobs =~ ^[1-9][0-9]*$ ]] ||
  die "e2e: invalid $hook_jobs_source value: $hook_jobs (expected a positive integer)"
if [[ -n $expected_base ]]; then
  [[ $expected_base =~ ^[0-9a-f]{40}$ ]] || die "e2e: invalid --expected-remote-base OID: $expected_base"
  ((!skip_repo)) || die "e2e: --expected-remote-base cannot be combined with --skip-repo-checks"
fi
if [[ -n $generation ]]; then
  [[ -d $generation ]] || die "e2e: generation not found: $generation"
  generation=$(cd -P -- "$generation" && pwd)
fi
explicit_generation=$generation

# --- Findings -------------------------------------------------------------

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-e2e.XXXXXX")
SKILLS_FINDINGS_FILE=$work_dir/findings.jsonl
: >"$SKILLS_FINDINGS_FILE"
SKILLS_KEEP_GOING=$keep_going
SKILLS_STEP=setup
failed=0
# Set once the configuration is loaded: from then on the run is recorded.
record_ready=0
# Set when the run reached its end: a run a signal ended did not pass.
finished=0
# The parallel hooks that have not been reaped: PID -> index in their group.
declare -A e2e_running=()

# _e2e_stop_hooks: stops the parallel hooks that still run, SIGTERM to the
# process group of each (its session) and SIGKILL to those that still run
# 10 seconds later, and reaps them.
_e2e_stop_hooks() {
  local pid timer done_pid
  local -a pending=()
  ((${#e2e_running[@]})) || return 0
  for pid in "${!e2e_running[@]}"; do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM -- "$pid" 2>/dev/null || true
  done
  sleep 10 &
  timer=$!
  while ((${#e2e_running[@]})); do
    pending=("${!e2e_running[@]}")
    [[ -z $timer ]] || pending+=("$timer")
    done_pid=''
    wait -n -p done_pid "${pending[@]}" 2>/dev/null || true
    [[ -n ${done_pid:-} ]] || break
    if [[ $done_pid == "$timer" ]]; then
      timer=''
      for pid in "${!e2e_running[@]}"; do
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL -- "$pid" 2>/dev/null || true
      done
      continue
    fi
    unset "e2e_running[$done_pid]"
    # Whatever the hook left running in its session.
    kill -KILL -- "-$done_pid" 2>/dev/null || true
  done
  if [[ -n $timer ]]; then
    kill -TERM -- "$timer" 2>/dev/null || true
    wait "$timer" 2>/dev/null || true
  fi
  e2e_running=()
}

# _e2e_write_result STATUS: the result of the run in the E2E record. Runs
# in a subshell of the exit trap: a failure to write it is a finding there.
_e2e_write_result() {
  local status=$1 count result=failed tree='' head='' top
  count=$(_e2e_findings_count)
  if ((status == 0 && count == 0)); then
    result=passed
  fi
  # The tree only of a checkout that is the top of its own work tree (the
  # check functions may not be defined yet when setup failed).
  top=$(git -C "$DS_INSTANCE_ROOT" rev-parse --show-toplevel 2>/dev/null) || top=''
  if [[ -n $top && $(cd -P -- "$top" && pwd) == "$(cd -P -- "$DS_INSTANCE_ROOT" && pwd)" ]]; then
    tree=$(git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet 'HEAD^{tree}') || tree=''
    head=$(git -C "$DS_INSTANCE_ROOT" rev-parse --verify --quiet 'HEAD^{commit}') || head=''
  fi
  txn_ensure_state_dir
  jq -n --arg result "$result" --arg tree "$tree" --arg head "$head" --arg generation "$generation" \
    --arg profile "$profile" --arg override "$framework_override" --argjson repo "$((!skip_repo))" \
    --argjson findings "$count" --arg root "$DS_INSTANCE_ROOT" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def maybe: if . == "" then null else . end;
    {schema_version: "1.0", result: $result, tree_oid: ($tree | maybe), head_oid: ($head | maybe),
     generation: ($generation | maybe), profile: $profile, framework_override: ($override | maybe),
     repo_checks: ($repo == 1), findings: $findings, root: $root, recorded_at: $at}' |
    txn_write_private "$(txn_e2e_file)"
}

_e2e_exit() {
  local status=$?
  _e2e_stop_hooks
  # A signal can end the run with status 0 here (bash exits with the
  # signal's status afterwards): it is a failed run.
  if ((status == 0 && !finished && !list)); then
    status=1
  fi
  if ((record_ready && !list && ${#scope[@]} == 0)); then
    (_e2e_write_result "$status") || status=1
  fi
  if ((json && !list)); then
    jq -s --argjson status "$status" \
      '{ result: (if $status == 0 and length == 0 then "passed" else "failed" end), findings: . }' \
      "$SKILLS_FINDINGS_FILE" >&3 || true
  fi
  cleanup_temp_dir "$work_dir"
  exit "$status"
}
trap _e2e_exit EXIT

# Every error from here on is a finding: library code reports through die.
die() {
  skills_finding "${SKILLS_DIE_CODE:-error}" "${SKILLS_DIE_PATH:-}" "$*"
  exit 1
}

# With --json, everything but the report goes to standard error.
if ((json && !list)); then
  exec 3>&1 1>&2
fi

_e2e_findings_count() {
  local count
  count=$(wc -l <"$SKILLS_FINDINGS_FILE")
  printf '%s\n' "$((count))"
}

# _e2e_record CODE PATH MESSAGE: a finding without an error line (for
# findings a child command already printed).
_e2e_record() {
  jq -cn --arg step "$SKILLS_STEP" --arg code "$1" --arg path "$2" --arg message "$3" \
    '{ step: $step, path: $path, code: $code, message: $message }' >>"$SKILLS_FINDINGS_FILE"
}

# _e2e_unit ID FUNCTION [ARG...]: runs one check in a subshell (with
# errexit). A failure without a finding gets a generic one. Fail-fast: the
# run ends with status 1; keep-going: the failure is recorded.
_e2e_unit() {
  local id=$1 before status
  shift
  before=$(_e2e_findings_count)
  set +e
  (
    set -e
    SKILLS_STEP=$id
    SKILLS_DIE_CODE='error'
    SKILLS_DIE_PATH=''
    "$@"
  )
  status=$?
  set -e
  ((status != 0)) || return 0
  if (($(_e2e_findings_count) == before)); then
    SKILLS_STEP=$id skills_finding failed "" "check $id failed (exit $status)"
  fi
  ((keep_going)) || exit 1
  failed=1
}

# _e2e_fail_or_continue: inside a check that goes over several items, after
# a finding: fail-fast ends the check, keep-going goes on with the next item.
_e2e_fail_or_continue() {
  ((keep_going)) || exit 1
}

# _e2e_home_path PATH: ~/x -> $HOME/x; absolute paths unchanged.
_e2e_home_path() {
  case $1 in
    \~/?*) printf '%s\n' "$HOME/${1#\~/}" ;;
    /?*) printf '%s\n' "$1" ;;
    *) die "invalid path in the manifest (expected ~/... or an absolute path): $1" ;;
  esac
}

# _e2e_manifest_path VALUE: the file a manifest path names: <instance>/ and
# <dotsteward>/ paths of the mirror are resolved, <store>/ paths need a
# generation (a source-unresolvable finding, status 1).
_e2e_manifest_path() {
  case $1 in
    "<instance>/"?*) printf '%s\n' "$DS_INSTANCE_ROOT/${1#"<instance>/"}" ;;
    "<dotsteward>/"?*) printf '%s\n' "$DOTSTEWARD_FRAMEWORK_ROOT/${1#"<dotsteward>/"}" ;;
    "<store>/"*)
      skills_finding source-unresolvable "$1" \
        "$1 is a Nix store path the manifest mirror does not carry; pass --generation with a built generation"
      return 1
      ;;
    /?*) printf '%s\n' "$1" ;;
    *) die "unsupported path in the manifest: $1" ;;
  esac
}

# _e2e_same_bytes A B: status 0 when the regular files A and B are equal.
_e2e_same_bytes() {
  [[ -f $1 && -f $2 ]] && [[ $(sha256_file "$1") == "$(sha256_file "$2")" ]]
}

# --- Setup ----------------------------------------------------------------

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
record_ready=1
require_profile "$profile"
require_safe_identity
source_nix_daemon
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
for tool in find jq realpath sha256sum sort stat; do
  require_command "$tool"
done

if [[ -z $generation ]]; then
  generation=$(skills_active_generation)
fi
methods_manifest_load "$generation"
methods_unavailable_notes

# The planners and checks read the manifest sections below with jq in
# command and process substitutions, whose errors bash does not report: a
# section with the wrong shape would read as nothing to check. They are
# checked once, here, with a status-checked jq call.
_e2e_manifest_shape() {
  jq -e '
    def optional(f): . == null or f;
    def string_list: type == "array" and all(.[]; type == "string");
    def hooks: type == "array" and all(.[]; type == "object"
      and (.component | type) == "string" and (.name | type) == "string"
      and (.script | type) == "string" and (.phase | optional(type == "string"))
      and (.profiles | optional(string_list)) and (.parallel | optional(type == "boolean")));
    (.components | type == "array" and all(.[]; type == "object"
      and (.name | type) == "string" and (.modes | optional(type == "object"))
      and (.platforms | optional(string_list))))
    and (.checks | optional(type == "object"
      and (.commands | optional(type == "array" and all(.[]; type == "object"
        and (.command | type) == "string" and (.component | type) == "string")))
      and (.e2e | optional(hooks))))
    and (.managed_links | optional(string_list))
    and (.agent_rules | optional(type == "object"
      and (.source | optional(type == "string"))
      and (.targets | optional(type == "array" and all(.[]; type == "object"
        and (.component | type) == "string" and (.path | type) == "string")))))
    and (.files | optional(type == "object" and all(.[]; type == "object"
      and (.source | type) == "string" and (.target | type) == "string"
      and (.mode | optional(type == "string")) and (.policy | optional(type == "string")))))
    and (.skills | optional(type == "object" and (.framework | optional(string_list))))
    and (.login_shell | optional(type == "string"))' <<<"$DS_MANIFEST_JSON" >/dev/null 2>&1
}
_e2e_manifest_shape ||
  skills_fail error "$DS_MANIFEST_FILE" \
    "invalid manifest $DS_MANIFEST_FILE: a section the E2E checks read (components, checks.commands, checks.e2e, managed_links, agent_rules, files, skills.framework or login_shell) has the wrong shape"
skills_init "$profile" 1 "$generation"
# A built generation's commands come first, like after its activation.
if [[ -n $explicit_generation ]]; then
  export PATH="$explicit_generation/home-path/bin:$PATH"
fi

active_text=$(methods_components "$profile")
mapfile -t active < <(grep -v '^$' <<<"$active_text" || true)
active_json=$(printf '%s\n' "${active[@]}" | grep -v '^$' | jq -R . | jq -cs .) || active_json='[]'
buffer_file=$(config_instance_path "${DS_SETTINGS_BUFFER_DIR:-local-maintained-files}/buffer.toml")

# _e2e_hooks PHASE: the checks.e2e hooks of PHASE to run, one JSON object
# per line, in [components] order, then declaration order.
_e2e_hooks() {
  jq -c --arg phase "$1" --arg profile "$profile" --argjson active "$active_json" '
    [(.checks.e2e // []) | to_entries[]
      | .value as $hook
      | select(($hook.phase // "main") == $phase)
      | select($active | index($hook.component))
      | select($hook.profiles == null or ($hook.profiles | index($profile)))
      | { key: [($active | index($hook.component)), .key], hook: ($hook + { list: "checks.e2e" }) }]
    | sort_by(.key)[] | .hook' <<<"$DS_MANIFEST_JSON"
}

# _e2e_plan: the checks to run, one "ID<TAB>KIND<TAB>ARGUMENT" line each,
# in run order.
_e2e_plan() {
  local component
  if [[ -n $(_e2e_commands_list) ]]; then
    printf 'core:commands\tcommands\t\n'
  fi
  _e2e_plan_hooks early
  if jq -e '(.managed_links // []) | length > 0' <<<"$DS_MANIFEST_JSON" >/dev/null; then
    printf 'core:managed-links\tmanaged-links\t\n'
  fi
  while IFS= read -r component; do
    [[ -n $component ]] && printf '%s:agent-rules\tagent-rules\t%s\n' "$component" "$component"
  done < <(jq -r --argjson active "$active_json" '
    (.agent_rules // {}) as $rules
    | if $rules.source == null then empty
      else $active[] as $component
        | select(any(($rules.targets // [])[]; .component == $component)) | $component end' \
    <<<"$DS_MANIFEST_JSON")
  if jq -e '(.files // {}) | length > 0' <<<"$DS_MANIFEST_JSON" >/dev/null; then
    printf 'core:files\tfiles\t\n'
  fi
  printf 'core:agents\tagents\t\n'
  if [[ -f $buffer_file ]]; then
    printf 'core:settings-files\tsettings-files\t\n'
    printf 'core:settings-verify\tsettings-verify\t\n'
  fi
  _e2e_plan_hooks main
  if jq -e '.login_shell != null' <<<"$DS_MANIFEST_JSON" >/dev/null; then
    printf 'core:login-shell\tlogin-shell\t\n'
  fi
  if [[ $DS_RUNTIME_PLATFORM == linux && -f ${DOTSTEWARD_SYSTEM_ROOT:-}/var/lib/dpkg/status ]]; then
    printf 'core:apt-files\tapt-files\t\n'
  fi
  if ((!skip_repo)); then
    printf 'core:repo-clean\trepo-clean\t\n'
    printf 'core:repo-origin\trepo-origin\t\n'
    printf 'core:repo-remote\trepo-remote\t\n'
    printf 'core:repo-skill-count\trepo-skill-count\t\n'
  fi
  _e2e_plan_hooks late
  printf 'core:framework-skills\tframework-skills\t\n'
}

# _e2e_plan_hooks PHASE: the plan rows of the hooks of PHASE, kind hook, or
# parallel-hook for a hook whose entry says parallel: true.
_e2e_plan_hooks() {
  local hook id_kind
  while IFS= read -r hook; do
    [[ -n $hook ]] || continue
    id_kind=$(jq -r '"\(.component):\(.name)\t\(if .parallel == true then "parallel-hook" else "hook" end)"' <<<"$hook")
    printf '%s\t%s\n' "$id_kind" "$hook"
  done < <(_e2e_hooks "$1")
}

# _e2e_commands_list: the commands to find, once each, in order.
_e2e_commands_list() {
  jq -r --argjson active "$active_json" '
    [(.checks.commands // [])[]
      | select(.component == "core" or (.component as $c | $active | index($c)))
      | .command]
    | reduce .[] as $command ([]; if index([$command]) then . else . + [$command] end)
    | .[]' <<<"$DS_MANIFEST_JSON"
}

# _e2e_in_scope ID: true when the check ID belongs to the run, which is every
# check unless --component names some components.
_e2e_in_scope() {
  local name
  ((${#scope[@]})) || return 0
  for name in "${scope[@]}"; do
    [[ $1 == "$name:"* ]] && return 0
  done
  return 1
}

for name in "${scope[@]}"; do
  [[ " ${active[*]} " == *" $name "* ]] ||
    die "e2e: --component $name: not an active component of profile $profile"
done

plan_text=$(_e2e_plan)
plan=()
while IFS= read -r row; do
  [[ -n $row ]] && _e2e_in_scope "${row%%$'\t'*}" && plan+=("$row")
done <<<"$plan_text"

if ((list)); then
  ids=()
  for row in "${plan[@]}"; do
    ids+=("${row%%$'\t'*}")
  done
  if ((json)); then
    jq -n --arg profile "$profile" '{ profile: $profile, checks: $ARGS.positional }' --args "${ids[@]}"
  else
    printf '%s\n' "${ids[@]}"
  fi
  exit 0
fi

# Every hook script resolves before any check runs.
parallel_hooks=0
for row in "${plan[@]}"; do
  IFS=$'\t' read -r _ kind argument <<<"$row"
  case $kind in
    hook) methods_hook_path "$argument" >/dev/null ;;
    parallel-hook)
      methods_hook_path "$argument" >/dev/null
      parallel_hooks=1
      ;;
  esac
done
if ((hook_jobs > 1 && parallel_hooks)); then
  if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1))); then
    warn "e2e: parallel hooks need bash 5.1 or newer (this is bash $BASH_VERSION); they run one at a time"
    hook_jobs=1
  else
    require_command python3
  fi
fi

if [[ -n $framework_override ]]; then
  log "framework override: $framework_override"
fi

# --- Checks ---------------------------------------------------------------

_e2e_commands() {
  local command search unit_failed=0
  search=$(user_path)
  while IFS= read -r command; do
    [[ -n $command ]] || continue
    if ! PATH=$search command -v -- "$command" >/dev/null 2>&1; then
      skills_finding missing-command "$command" "required command not found: $command"
      _e2e_fail_or_continue
      unit_failed=1
    fi
  done < <(_e2e_commands_list)
  ((unit_failed == 0)) || exit 1
}

_e2e_hook() {
  local hook=$1 component name status=0
  component=$(jq -r '.component' <<<"$hook")
  name=$(jq -r '.name' <<<"$hook")
  SKILLS_DIE_CODE='hook-failed'
  SKILLS_DIE_PATH=$component/$name
  methods_run_hook "$hook" "$profile" 1 || status=$?
  ((status == 0)) ||
    skills_fail hook-failed "$component/$name" "component $component hook $name failed (exit $status)"
}

_e2e_managed_links() {
  local link path unit_failed=0
  while IFS= read -r -d '' link; do
    path=$(_e2e_home_path "$link")
    if [[ ! -L $path ]]; then
      if [[ -e $path ]]; then
        skills_finding managed-link-not-symlink "$path" "not a Home Manager symlink: $path"
      else
        skills_finding managed-link-missing "$path" "managed link missing: $path"
      fi
    elif [[ ! -e $path ]]; then
      skills_finding managed-link-broken "$path" "broken symlink: $path"
    else
      continue
    fi
    _e2e_fail_or_continue
    unit_failed=1
  done < <(jq -j --argjson inactive "$(methods_inactive_components "$profile")" '
    [$inactive[] as $name | (.component_managed_links[$name] // [])[]] as $out
    | ((.managed_links // []) - $out)[] | ., "\u0000"' <<<"$DS_MANIFEST_JSON")
  ((unit_failed == 0)) || exit 1
}

_e2e_agent_rules() {
  local component=$1 raw source target path unit_failed=0
  raw=$(jq -r '.agent_rules.source' <<<"$DS_MANIFEST_JSON")
  source=$(_e2e_manifest_path "$raw") || exit 1
  [[ -f $source ]] || skills_fail source-missing "$source" "agent rules source not found: $source"
  while IFS= read -r -d '' target; do
    [[ -n $target && $target != /* && $target != \~* ]] ||
      die "invalid agent rules target of component $component (expected a path relative to the home directory): $target"
    path=$HOME/$target
    if [[ ! -e $path ]]; then
      skills_finding agent-rules-missing "$path" "agent rules missing: $path"
    elif ! _e2e_same_bytes "$source" "$path"; then
      skills_finding agent-rules-mismatch "$path" "agent rules differ from $source: $path"
    else
      continue
    fi
    _e2e_fail_or_continue
    unit_failed=1
  done < <(jq -j --arg component "$component" \
    '(.agent_rules.targets // [])[] | select(.component == $component) | .path, "\u0000"' <<<"$DS_MANIFEST_JSON")
  ((unit_failed == 0)) || exit 1
}

# _e2e_mode PATH: the permission bits of PATH as four octal digits.
_e2e_mode() {
  local mode
  mode=$(stat -c '%a' -- "$1")
  printf '%04o\n' "$((8#$mode))"
}

_e2e_files() {
  local id raw target mode policy path source actual expected unit_failed=0 item_failed
  while IFS=$'\t' read -r id raw target mode policy; do
    [[ -n $id ]] || continue
    path=$(_e2e_home_path "$target")
    item_failed=0
    if [[ -L $path || (-e $path && ! -f $path) ]]; then
      skills_finding file-not-regular "$path" "file $id is not a regular file: $path"
      item_failed=1
    elif [[ ! -e $path ]]; then
      skills_finding file-missing "$path" "file $id missing: $path"
      item_failed=1
    elif [[ $policy == always ]]; then
      if ! source=$(_e2e_manifest_path "$raw"); then
        item_failed=1
      elif [[ ! -f $source ]]; then
        skills_finding source-missing "$source" "file $id source not found: $source"
        item_failed=1
      else
        if ! _e2e_same_bytes "$source" "$path"; then
          skills_finding file-content-mismatch "$path" "file $id differs from $source: $path"
          item_failed=1
        fi
        actual=$(_e2e_mode "$path")
        expected=$(printf '%04o' "$((8#$mode))")
        if [[ $actual != "$expected" ]]; then
          skills_finding file-mode-mismatch "$path" "file $id has mode $actual, expected $expected: $path"
          item_failed=1
        fi
      fi
    fi
    if ((item_failed)); then
      _e2e_fail_or_continue
      unit_failed=1
    fi
  done < <(jq -r '(.files // {}) | to_entries | sort_by(.key)[]
    | [.key, .value.source, .value.target, (.value.mode // "0644"), (.value.policy // "always")] | @tsv' \
    <<<"$DS_MANIFEST_JSON")
  ((unit_failed == 0)) || exit 1
}

_e2e_agents() {
  local status=0 count
  local -a args=(--instance "$DS_INSTANCE_ROOT" agents check --profile "$profile" --json)
  [[ -z $explicit_generation ]] || args+=(--generation "$explicit_generation")
  ((!keep_going)) || args+=(--keep-going)
  "$DOTSTEWARD_FRAMEWORK_ROOT/cli/dotsteward" "${args[@]}" >"$work_dir/agents.json" || status=$?
  ((status != 0)) || return 0
  count=$(jq -r '(.findings // []) | length' "$work_dir/agents.json" 2>/dev/null) || count=0
  if ((count == 0)); then
    skills_fail agents-failed "" "agents check failed (exit $status)"
  fi
  # The agents check printed its findings already. Its validation repeats
  # checks.commands, so a finding an earlier check reported (same code and
  # path) is not recorded twice; when nothing new remains, the earlier
  # check's failure already fails the run. Fields are separated by the unit
  # separator, which read never merges.
  local new=0
  while IFS=$'\x1f' read -r -d '' code path message; do
    _e2e_record "$code" "$path" "$message"
    new=$((new + 1))
  done < <(jq -j --slurpfile known "$SKILLS_FINDINGS_FILE" '
    [$known[] | [.code, .path]] as $seen
    | .findings[] | select([.code, .path] as $key | $seen | index([$key]) | not)
    | .code, "\u001f", .path, "\u001f", "\(.step): \(.message)", "\u0000"' "$work_dir/agents.json")
  ((new == 0)) || exit 1
}

# _e2e_settings_args: the settings options of this run.
_e2e_settings_args() {
  printf '%s\0' --repo "$DS_INSTANCE_ROOT" --home "$HOME" \
    --state-dir "$(state_root)/local-maintained-files" --targets-file "$DS_MANIFEST_FILE" \
    --inactive-components "$(methods_inactive_components "$profile")"
}

_e2e_settings_files() {
  local kind name path output unit_failed=0
  local -a args=()
  mapfile -d '' -t args < <(_e2e_settings_args)
  require_command python3
  # The engine resolves the targets (a buffer target replaces a component
  # target of the same name) and the entries exactly as verify does.
  output=$(PYTHONPATH=$DOTSTEWARD_FRAMEWORK_ROOT/engines/local-maintained-files:$DOTSTEWARD_FRAMEWORK_ROOT/cli/python \
    PYTHONDONTWRITEBYTECODE=1 python3 -s -P - "${args[@]}" <<'PY'
import sys

import local_maintained_files as lmf

try:
    context = lmf.resolve_context(lmf.parse_args([*sys.argv[1:], "status"]))
    buffer = lmf.Buffer(context)
except (lmf.LmfError, OSError) as error:
    messages = error.messages if isinstance(error, lmf.LmfError) else [str(error)]
    for message in messages:
        print(f"error\x1f\x1f{message}")
    sys.exit(0)
seen = set()
for entry in buffer.entries:
    if entry.kind == "file":
        if not entry.absent:
            print(f"file\x1f{entry.id}\x1f{lmf.expand(entry.path, context.home)}")
    elif entry.target.path is not None and entry.target.name not in seen:
        seen.add(entry.target.name)
        print(f"target\x1f{entry.target.name}\x1f{lmf.expand(entry.target.path, context.home)}")
PY
  ) || skills_fail settings-invalid "" "cannot read the settings buffer with python3 (it needs tomlkit)"
  while IFS=$'\x1f' read -r kind name path; do
    case $kind in
      error)
        skills_finding settings-invalid "" "$path"
        ;;
      file)
        if [[ -L $path || (-e $path && ! -f $path) ]]; then
          skills_finding settings-file-not-regular "$path" "settings file entry $name is not a regular file: $path"
        elif [[ ! -e $path ]]; then
          skills_finding settings-file-missing "$path" "settings file entry $name missing: $path"
        else
          continue
        fi
        ;;
      target)
        # A missing target is deferred until the application writes it.
        if [[ -L $path || (-e $path && ! -f $path) ]]; then
          skills_finding settings-file-not-regular "$path" "settings target $name is not a regular file: $path"
        else
          continue
        fi
        ;;
      *) continue ;;
    esac
    _e2e_fail_or_continue
    unit_failed=1
  done <<<"$output"
  ((unit_failed == 0)) || exit 1
}

_e2e_settings_verify() {
  local status=0 line message code path count=0
  local -a args=()
  mapfile -d '' -t args < <(_e2e_settings_args)
  "$DOTSTEWARD_FRAMEWORK_ROOT/cli/dotsteward" settings "${args[@]}" verify 2>"$work_dir/settings.err" || status=$?
  cat -- "$work_dir/settings.err" >&2
  ((status != 0)) || return 0
  code=settings-error
  ((status != 1)) || code=settings-not-converged
  # The engine printed its error lines already.
  while IFS= read -r line; do
    [[ $line == *"] ERROR: "* ]] || continue
    message=${line#*"] ERROR: "}
    path=''
    if [[ $code == settings-not-converged && $message =~ ^([A-Za-z0-9][A-Za-z0-9._-]*):\  ]]; then
      path=${BASH_REMATCH[1]}
    fi
    _e2e_record "$code" "$path" "$message"
    count=$((count + 1))
  done <"$work_dir/settings.err"
  ((count > 0)) || skills_fail "$code" "" "settings verify failed (exit $status); run 'dotsteward settings status' to inspect"
  exit 1
}

_e2e_login_shell() {
  local raw path current
  raw=$(jq -r '.login_shell' <<<"$DS_MANIFEST_JSON")
  # shellcheck disable=SC2016 # the literal text $HOME and ${HOME} is replaced
  path=${raw//'${HOME}'/$HOME}
  # shellcheck disable=SC2016 # the literal text $HOME and ${HOME} is replaced
  path=${path//'$HOME'/$HOME}
  [[ $path == /* ]] || die "invalid login shell in the manifest (expected an absolute path): $raw"
  if ! declare -F platform_login_shell >/dev/null || ! declare -F platform_shells_contains >/dev/null; then
    die "login shell checks are not available on $DS_RUNTIME_PLATFORM"
  fi
  [[ -x $path && ! -d $path ]] || skills_fail login-shell-not-executable "$path" "login shell is not executable: $path"
  platform_shells_contains "$path" ||
    skills_fail login-shell-not-listed "$path" "login shell is not listed in $(platform_shells_file): $path"
  current=$(platform_login_shell "$USER")
  [[ $current == "$path" ]] ||
    skills_fail login-shell-mismatch "$path" \
      "the login shell of $USER is $current, not $path; run 'dotsteward rebuild --profile $profile --switch' in a terminal"
}

# _e2e_apt_files: the files of the gated classes against what the apt engine
# writes now; a note for what waits for the first terminal run of upgrade.
_e2e_apt_files() {
  local output kind code path message failed=0
  # A check that cannot run says so; only the file itself can make this check red.
  if ! output=$(ds_python dotsteward_cli.apt_plan check-files --instance "$DS_INSTANCE_ROOT" 2>&1); then
    warn "core:apt-files: the pin file was not checked: ${output##*$'\n'}"
    return 0
  fi
  while IFS=$'\t' read -r kind code path message; do
    [[ -n $kind ]] || continue
    [[ $path != - ]] || path=''
    if [[ $kind == note ]]; then
      warn "core:apt-files: $message"
      continue
    fi
    skills_finding "$code" "$path" "$message"
    ((SKILLS_KEEP_GOING)) || exit 1
    failed=1
  done <<<"$output"
  ((failed == 0)) || exit 1
}

# _e2e_is_work_tree: the instance root is the top level of a git work tree.
_e2e_is_work_tree() {
  local top
  top=$(git -C "$DS_INSTANCE_ROOT" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n $top && $(cd -P -- "$top" && pwd) == "$(cd -P -- "$DS_INSTANCE_ROOT" && pwd)" ]]
}

_e2e_repo_clean() {
  local status
  ((is_work_tree)) ||
    skills_fail repo-not-git "$DS_INSTANCE_ROOT" "instance checkout is not a git work tree: $DS_INSTANCE_ROOT"
  status=$(git -C "$DS_INSTANCE_ROOT" status --porcelain) || die "git status failed in $DS_INSTANCE_ROOT"
  [[ -z $status ]] ||
    skills_fail repo-dirty "$DS_INSTANCE_ROOT" "instance checkout is not clean: $DS_INSTANCE_ROOT"
}

_e2e_repo_origin() {
  local url
  url=$(git -C "$DS_INSTANCE_ROOT" remote get-url origin 2>/dev/null) ||
    skills_fail repo-origin-missing "$DS_INSTANCE_ROOT" "the instance checkout has no origin remote: $DS_INSTANCE_ROOT"
  [[ $url == "$DS_INSTANCE_REMOTE" ]] ||
    skills_fail repo-origin-mismatch "$DS_INSTANCE_ROOT" \
      "origin of the instance checkout is $url, expected $DS_INSTANCE_REMOTE (instance.remote)"
}

_e2e_repo_remote() {
  local branch=${DS_INSTANCE_BRANCH:-main} output status=0 remote local_oid
  local_oid=$(git -C "$DS_INSTANCE_ROOT" rev-parse --verify HEAD 2>/dev/null) ||
    skills_fail remote-mismatch "$DS_INSTANCE_ROOT" "the instance checkout has no commit"
  output=$(git_net 30 -C "$DS_INSTANCE_ROOT" ls-remote origin "refs/heads/$branch" </dev/null) || status=$?
  ((status == 0)) ||
    skills_fail remote-unreachable "$DS_INSTANCE_ROOT" \
      "cannot read origin $branch of the instance checkout (git ls-remote exited with $status)"
  remote=$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1; exit }' <<<"$output")
  [[ -n $remote ]] ||
    skills_fail remote-unreachable "$DS_INSTANCE_ROOT" "cannot read origin $branch of the instance checkout (no such branch)"
  if [[ -n $expected_base ]]; then
    [[ $remote == "$expected_base" ]] ||
      skills_fail remote-base-moved "$DS_INSTANCE_ROOT" \
        "origin $branch is $remote, not the expected publish base $expected_base"
    git -C "$DS_INSTANCE_ROOT" merge-base --is-ancestor "$expected_base" "$local_oid" 2>/dev/null ||
      skills_fail base-not-ancestor "$DS_INSTANCE_ROOT" \
        "the expected publish base $expected_base is not an ancestor of HEAD $local_oid"
  elif [[ $local_oid != "$remote" ]] && ! _e2e_repo_behind "$local_oid" "$remote" "$branch"; then
    skills_fail remote-mismatch "$DS_INSTANCE_ROOT" "local HEAD $local_oid differs from origin $branch $remote"
  fi
}

# _e2e_repo_behind LOCAL REMOTE BRANCH: status 0, with a note, when LOCAL is an
# ancestor of REMOTE. A commit of the remote that is not here yet comes without a
# destination: no ref and no FETCH_HEAD to lock, and nothing a run has to clean up.
_e2e_repo_behind() {
  local local_oid=$1 remote=$2 branch=$3 count noun=commit status=0
  if ! git -C "$DS_INSTANCE_ROOT" cat-file -e "$remote^{commit}" 2>/dev/null; then
    git_net 60 -C "$DS_INSTANCE_ROOT" fetch --quiet --no-tags --no-auto-maintenance --no-write-fetch-head --refmap= \
      origin "refs/heads/$branch" </dev/null || status=$?
    ((status == 0)) ||
      skills_fail remote-unreachable "$DS_INSTANCE_ROOT" \
        "cannot fetch origin $branch of the instance checkout (git fetch exited with $status)"
  fi
  git -C "$DS_INSTANCE_ROOT" merge-base --is-ancestor "$local_oid" "$remote" 2>/dev/null || return 1
  count=$(git -C "$DS_INSTANCE_ROOT" rev-list --count "$local_oid..$remote")
  ((count == 1)) || noun=commits
  log "the checkout is $count $noun behind origin $branch; 'git pull --ff-only' moves it"
}

# The lock's entries are the expected skills; an expected_skill_count that
# older instances carry only copies their number and is ignored.
_e2e_repo_skill_count() {
  local vendor expected count
  vendor=${DS_SKILLS_VENDOR_DIR:-agent/skills}
  vendor=${vendor%/}
  [[ $vendor != /* ]] || vendor=${vendor#"$DS_INSTANCE_ROOT"/}
  [[ -f $SKILLS_LOCK ]] || die "skills lock not found: $SKILLS_LOCK"
  expected=$(jq -r '.skills | if type == "array" then length else "none" end' "$SKILLS_LOCK" 2>/dev/null) ||
    die "invalid skills lock: $SKILLS_LOCK"
  [[ $expected =~ ^[0-9]+$ ]] || die "invalid skills lock $SKILLS_LOCK: skills is not a list"
  count=$(git -C "$DS_INSTANCE_ROOT" ls-files -- ":(glob)$vendor/*/SKILL.md" | wc -l)
  count=$((count))
  ((count == expected)) ||
    skills_fail skill-count-mismatch "$SKILLS_LOCK" \
      "git tracks $count vendored skills ($vendor/*/SKILL.md), the skills lock lists $expected"
}

# _e2e_framework_skill PATH: one framework skill link (findings exit).
_e2e_framework_skill() {
  local path=$1 name real expected manifest entry skill_sha directory_sha
  name=${path##*/}
  if [[ ! -L $path ]]; then
    if [[ -e $path ]]; then
      skills_fail framework-skill-not-link "$path" "framework skill is not a Home Manager link: $path"
    fi
    skills_fail framework-skill-missing "$path" "framework skill missing: $name ($path); Home Manager activation links it"
  fi
  real=$(realpath -e -- "$path" 2>/dev/null) ||
    skills_fail framework-skill-broken "$path" "broken framework skill link: $path"
  expected=$(realpath -e -- "$generation/home-files/$SKILLS_HM_ROOT_REL/$name" 2>/dev/null) ||
    skills_fail framework-skill-not-in-generation "$path" "the generation has no framework skill $name: $path"
  [[ $real == "$expected" ]] ||
    skills_fail framework-skill-foreign "$path" "framework skill does not resolve to the generation's framework source: $path"
  manifest=$(dirname -- "$expected")/manifest.json
  entry=$(jq -c --arg name "$name" \
    'first((.skills // [])[] | select(.directory == $name or (.directory == null and .name == $name))) // empty' \
    "$manifest" 2>/dev/null) || entry=''
  [[ -n $entry ]] ||
    skills_fail framework-manifest-missing "$path" "framework skill $name is not in $manifest"
  skill_sha=$(jq -r '.skill_sha256 // empty' <<<"$entry")
  directory_sha=$(jq -r '.directory_sha256 // empty' <<<"$entry")
  if [[ ! -f $real/SKILL.md || $(sha256_file "$real/SKILL.md") != "$skill_sha" ||
    $(directory_sha256 "$real") != "$directory_sha" ]]; then
    skills_fail framework-skill-digest-mismatch "$path" "framework skill digest differs from $manifest: $name ($path)"
  fi
}

_e2e_framework_skills() {
  local path name unit_failed=0
  local -a paths=() names=()
  local -A seen=()
  if [[ -d $SKILLS_HM_ROOT ]]; then
    while IFS= read -r -d '' path; do
      paths+=("$path")
      seen[${path##*/}]=1
    done < <(find "$SKILLS_HM_ROOT" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' -print0 | LC_ALL=C sort -z)
  fi
  mapfile -t names < <(jq -r '(.skills.framework // [])[]' <<<"$DS_MANIFEST_JSON")
  for name in "${names[@]}"; do
    [[ -n $name && -z ${seen[$name]:-} ]] || continue
    paths+=("$SKILLS_HM_ROOT/$name")
    seen[$name]=1
  done
  ((${#paths[@]} > 0)) || return 0
  [[ -n $generation ]] ||
    skills_fail framework-skill-unverifiable "$SKILLS_HM_ROOT" \
      "no Home Manager generation to verify the framework skills against; pass --generation"
  mapfile -d '' -t paths < <(printf '%s\0' "${paths[@]}" | LC_ALL=C sort -z)
  for path in "${paths[@]}"; do
    if ! (_e2e_framework_skill "$path"); then
      _e2e_fail_or_continue
      unit_failed=1
    fi
  done
  ((unit_failed == 0)) || exit 1
}

# --- Parallel hooks -------------------------------------------------------

# Whether the run's standard output and error are the same file: a parallel
# hook's two streams then go to one file, which keeps their order.
one_stream=0
if [[ /dev/fd/1 -ef /dev/fd/2 ]]; then
  one_stream=1
fi
group_count=0

# _e2e_hook_start DIR INDEX ID HOOK: starts the parallel hook HOOK (check id
# ID, INDEX in its group) in the background; its output and findings go to
# DIR.
_e2e_hook_start() {
  local dir=$1 index=$2 id=$3 hook=$4 component name
  component=$(jq -r '.component' <<<"$hook")
  name=$(jq -r '.name' <<<"$hook")
  mkdir -p -- "$dir"
  : >"$dir/findings.jsonl"
  (
    SKILLS_STEP=$id
    SKILLS_DIE_CODE='hook-failed'
    SKILLS_DIE_PATH=$component/$name
    # shellcheck disable=SC2030 # the hook's own findings file, in its subshell only
    SKILLS_FINDINGS_FILE=$dir/findings.jsonl
    if ((one_stream)); then
      exec >"$dir/output" 2>&1
    else
      exec >"$dir/output" 2>"$dir/error"
    fi
    methods_exec_hook "$hook" "$profile" 1
  ) </dev/null &
  e2e_running[$!]=$index
}

# _e2e_hook_report DIR ID HOOK STATUS: reports a parallel hook that ended
# with STATUS as _e2e_unit and _e2e_hook report a hook that runs alone: its
# output, its findings, then its failure.
_e2e_hook_report() {
  local dir=$1 id=$2 hook=$3 status=$4 component name
  if [[ -f $dir/output ]]; then
    cat -- "$dir/output"
  fi
  if ((!one_stream)) && [[ -f $dir/error ]]; then
    cat -- "$dir/error" >&2
  fi
  # shellcheck disable=SC2031 # the run's findings file; the subshell had its own
  cat -- "$dir/findings.jsonl" >>"$SKILLS_FINDINGS_FILE"
  ((status != 0)) || return 0
  # A hook that could not start reported its own finding.
  if [[ ! -s $dir/findings.jsonl ]]; then
    component=$(jq -r '.component' <<<"$hook")
    name=$(jq -r '.name' <<<"$hook")
    SKILLS_STEP=$id skills_finding hook-failed "$component/$name" "component $component hook $name failed (exit $status)"
  fi
  ((keep_going)) || exit 1
  failed=1
}

# _e2e_hook_group ROW...: runs the parallel hooks of the plan rows ROW...
# (consecutive, of one phase), at most hook_jobs at a time, and reports
# each one in plan order once it and every hook before it ended. Without
# --keep-going no hook starts after one failed.
_e2e_hook_group() {
  local -a rows=("$@") dirs=()
  local -A ended=()
  local count=$# next=0 report=0 stop=0 status pid id hook i
  group_count=$((group_count + 1))
  for ((i = 0; i < count; i++)); do
    dirs[i]=$work_dir/hooks/$group_count/$i
  done
  while ((report < count)); do
    while ((!stop && next < count && ${#e2e_running[@]} < hook_jobs)); do
      IFS=$'\t' read -r id _ hook <<<"${rows[next]}"
      _e2e_hook_start "${dirs[next]}" "$next" "$id" "$hook"
      next=$((next + 1))
    done
    if [[ -n ${ended[$report]:-} ]]; then
      IFS=$'\t' read -r id _ hook <<<"${rows[report]}"
      _e2e_hook_report "${dirs[report]}" "$id" "$hook" "${ended[$report]}"
      report=$((report + 1))
      continue
    fi
    pid=''
    status=0
    wait -n -p pid "${!e2e_running[@]}" || status=$?
    [[ -n ${pid:-} && -n ${e2e_running[$pid]:-} ]] || die "e2e: lost track of the parallel hooks"
    ended[${e2e_running[$pid]}]=$status
    unset "e2e_running[$pid]"
    if ((status != 0 && !keep_going)); then
      stop=1
    fi
  done
}

# The rows of consecutive parallel hooks of one phase, run together once
# the next row is of another kind or phase.
hook_group=()
hook_group_phase=''

_e2e_run_group() {
  ((${#hook_group[@]})) || return 0
  _e2e_hook_group "${hook_group[@]}"
  hook_group=()
}

# --- Run ------------------------------------------------------------------

is_work_tree=0
if ((!skip_repo)) && _e2e_is_work_tree; then
  is_work_tree=1
fi

for row in "${plan[@]}"; do
  IFS=$'\t' read -r id kind argument <<<"$row"
  if [[ $kind == parallel-hook ]] && ((hook_jobs > 1)); then
    row_phase=$(jq -r '.phase // "main"' <<<"$argument")
    [[ $row_phase == "$hook_group_phase" ]] || _e2e_run_group
    hook_group_phase=$row_phase
    hook_group+=("$row")
    continue
  fi
  _e2e_run_group
  case $kind in
    commands) _e2e_unit "$id" _e2e_commands ;;
    hook | parallel-hook) _e2e_unit "$id" _e2e_hook "$argument" ;;
    managed-links) _e2e_unit "$id" _e2e_managed_links ;;
    agent-rules) _e2e_unit "$id" _e2e_agent_rules "$argument" ;;
    files) _e2e_unit "$id" _e2e_files ;;
    agents) _e2e_unit "$id" _e2e_agents ;;
    settings-files) _e2e_unit "$id" _e2e_settings_files ;;
    settings-verify) _e2e_unit "$id" _e2e_settings_verify ;;
    login-shell) _e2e_unit "$id" _e2e_login_shell ;;
    apt-files) _e2e_unit "$id" _e2e_apt_files ;;
    repo-clean) _e2e_unit "$id" _e2e_repo_clean ;;
    repo-origin | repo-remote | repo-skill-count)
      # Without a work tree, repo-clean reported it; the rest cannot run.
      if ((is_work_tree)); then
        _e2e_unit "$id" "_e2e_${kind//-/_}"
      fi
      ;;
    framework-skills) _e2e_unit "$id" _e2e_framework_skills ;;
    *) die "e2e: unknown check kind: $kind" ;;
  esac
done
_e2e_run_group

finished=1
if ((failed)); then
  printf '[dotsteward] ERROR: e2e failed: %s findings\n' "$(_e2e_findings_count)" >&2
  exit 1
fi
if ((${#scope[@]})); then
  log "e2e checks of ${scope[*]} passed (profile $profile)"
else
  log "e2e checks passed (profile $profile)"
fi
