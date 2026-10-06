#!/usr/bin/env bash
# summary: Verify this machine against the instance: the end-to-end checks of a profile
#
# The E2E runner (SPEC 8.3). Checks, in run order, each with an id
# (<component>:<check-name> or core:<check-name>) that --list prints:
#    1. flags, configuration, profile, the Nix environment
#    2. core:commands             the union of checks.commands of core and
#                                 the active components is on PATH
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
#    9. core:repo-clean           the instance checkout is a clean git work
#                                 tree
#       core:repo-origin          origin equals instance.remote
#       core:repo-remote          origin <branch>, read with git_net, equals
#                                 HEAD; with --expected-remote-base OID it
#                                 equals OID and OID is an ancestor of HEAD
#       core:repo-skill-count     the vendored SKILL.md files git tracks
#                                 match the skills lock count
#   10. <component>:<hook>        late checks.e2e hooks
#   11. core:framework-skills     every <hm_root>/dotsteward-* link and every
#                                 framework skill of the manifest resolves to
#                                 the generation's framework source with the
#                                 digests of its skills/manifest.json
#   12. the success line
# Hooks run for the components active in the profile, in [components]
# order, then declaration order, when their profiles include the profile,
# with the hook environment (SPEC 8.4) and DOTSTEWARD_CHECK_ONLY=1. A check
# with nothing to verify is not listed and does not run: no commands, no
# managed links, no agent rules source or targets, no files, no settings
# buffer, no login shell; --skip-repo-checks drops step 9.
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
#   login-shell-not-listed, login-shell-mismatch; repo-not-git, repo-dirty,
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

usage() {
  cat <<'EOF'
Usage: dotsteward e2e --profile PROFILE [--expected-remote-base OID]
                      [--framework-override REF] [--generation PATH]
                      [--keep-going] [--json] [--list] [--skip-repo-checks]

Verifies that this machine matches the instance for PROFILE after a
rebuild: commands, component E2E hooks, managed links, agent rules, files,
the agents check, tracked settings, the login shell, the instance checkout
and its remote, and the framework skills of the generation.

  --profile PROFILE          a profile of the instance (required)
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
keep_going=0
json=0
list=0
skip_repo=0

# _e2e_value OPTION ARGC VALUE: a non-empty option value.
_e2e_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    die "e2e: $1 requires a value"
  fi
}

while (($#)); do
  case $1 in
    --profile | --expected-remote-base | --framework-override | --generation)
      _e2e_value "$1" "$#" "${2:-}"
      case $1 in
        --profile) profile=$2 ;;
        --expected-remote-base) expected_base=$2 ;;
        --framework-override) framework_override=$2 ;;
        --generation) generation=$2 ;;
      esac
      shift 2
      ;;
    --profile=* | --expected-remote-base=* | --framework-override=* | --generation=*)
      _e2e_value "${1%%=*}" 2 "${1#*=}"
      case $1 in
        --profile=*) profile=${1#*=} ;;
        --expected-remote-base=*) expected_base=${1#*=} ;;
        --framework-override=*) framework_override=${1#*=} ;;
        --generation=*) generation=${1#*=} ;;
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

_e2e_exit() {
  local status=$?
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
  if ((!skip_repo)); then
    printf 'core:repo-clean\trepo-clean\t\n'
    printf 'core:repo-origin\trepo-origin\t\n'
    printf 'core:repo-remote\trepo-remote\t\n'
    printf 'core:repo-skill-count\trepo-skill-count\t\n'
  fi
  _e2e_plan_hooks late
  printf 'core:framework-skills\tframework-skills\t\n'
}

_e2e_plan_hooks() {
  local hook id
  while IFS= read -r hook; do
    [[ -n $hook ]] || continue
    id=$(jq -r '"\(.component):\(.name)"' <<<"$hook")
    printf '%s\thook\t%s\n' "$id" "$hook"
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

plan_text=$(_e2e_plan)
mapfile -t plan < <(grep -v '^$' <<<"$plan_text" || true)

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
for row in "${plan[@]}"; do
  IFS=$'\t' read -r _ kind argument <<<"$row"
  if [[ $kind == hook ]]; then
    methods_hook_path "$argument" >/dev/null
  fi
done

if [[ -n $framework_override ]]; then
  log "framework override: $framework_override"
fi

# --- Checks ---------------------------------------------------------------

_e2e_commands() {
  local command unit_failed=0
  while IFS= read -r command; do
    [[ -n $command ]] || continue
    if ! command -v -- "$command" >/dev/null 2>&1; then
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
  done < <(jq -j '(.managed_links // [])[] | ., "\u0000"' <<<"$DS_MANIFEST_JSON")
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
    --state-dir "$(state_root)/local-maintained-files" --targets-file "$DS_MANIFEST_FILE"
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
  elif [[ $local_oid != "$remote" ]]; then
    skills_fail remote-mismatch "$DS_INSTANCE_ROOT" "local HEAD $local_oid differs from origin $branch $remote"
  fi
}

_e2e_repo_skill_count() {
  local vendor expected count
  vendor=${DS_SKILLS_VENDOR_DIR:-agent/skills}
  vendor=${vendor%/}
  [[ $vendor != /* ]] || vendor=${vendor#"$DS_INSTANCE_ROOT"/}
  [[ -f $SKILLS_LOCK ]] || die "skills lock not found: $SKILLS_LOCK"
  expected=$(jq -r '.expected_skill_count' "$SKILLS_LOCK") || die "invalid skills lock: $SKILLS_LOCK"
  [[ $expected =~ ^[0-9]+$ ]] || die "invalid skills lock $SKILLS_LOCK: expected_skill_count is not a count"
  count=$(git -C "$DS_INSTANCE_ROOT" ls-files -- ":(glob)$vendor/*/SKILL.md" | wc -l)
  count=$((count))
  ((count == expected)) ||
    skills_fail skill-count-mismatch "$SKILLS_LOCK" \
      "git tracks $count vendored skills ($vendor/*/SKILL.md), the skills lock expects $expected"
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

# --- Run ------------------------------------------------------------------

is_work_tree=0
if ((!skip_repo)) && _e2e_is_work_tree; then
  is_work_tree=1
fi

for row in "${plan[@]}"; do
  IFS=$'\t' read -r id kind argument <<<"$row"
  case $kind in
    commands) _e2e_unit "$id" _e2e_commands ;;
    hook) _e2e_unit "$id" _e2e_hook "$argument" ;;
    managed-links) _e2e_unit "$id" _e2e_managed_links ;;
    agent-rules) _e2e_unit "$id" _e2e_agent_rules "$argument" ;;
    files) _e2e_unit "$id" _e2e_files ;;
    agents) _e2e_unit "$id" _e2e_agents ;;
    settings-files) _e2e_unit "$id" _e2e_settings_files ;;
    settings-verify) _e2e_unit "$id" _e2e_settings_verify ;;
    login-shell) _e2e_unit "$id" _e2e_login_shell ;;
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

if ((failed)); then
  printf '[dotsteward] ERROR: e2e failed: %s findings\n' "$(_e2e_findings_count)" >&2
  exit 1
fi
log "e2e checks passed (profile $profile)"
