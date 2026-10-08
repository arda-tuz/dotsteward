#!/usr/bin/env bash
# summary: Install or check the agent tools, the skill layout and the agents checks of a profile
#
# Installs or checks the agent tools and the skill layout of a profile.
# Phases, in this order:
#   1. official-binary   every active official-binary component: installed
#                        at the user level (install) or checked by its pin
#                        policy (check); then the agentsInstall hooks
#   2. layout            the canonical skill root ~/.agents/skills, the
#                        legacy roots and the excluded subtrees
#   3. skills            the framework skills of the manifest first, then the
#                        instance skills lock entries in file order
#   4. sweep             dangling links into the managed skill roots
#   5. agentsMigrate hooks, 6. agentsPost hooks
#   7. validation        checks.commands, checks.floors, the probe registry,
#                        then the checks.agents hooks
# Hooks run in both modes (DOTSTEWARD_CHECK_ONLY tells them which) in
# [components] order, then declaration order, for the components active in
# the profile. The skill layout engine is cli/lib/skills.sh, the method
# engine cli/lib/methods.sh, the probe runner cli/lib/probes.sh.
#
# Findings have a step (official-binary, agents-install, layout,
# framework-skills, skills, sweep, agents-migrate, agents-post, commands,
# floors, probes, agents-checks, or setup), a path (the file, the command,
# <component>/<hook> or the component), a code and a message. Without
# --keep-going the first finding ends the command. With --keep-going every
# failure is recorded and the command goes on where the next step does not
# depend on the failed one: a failed layout skips the skills and the sweep,
# a failed skill only itself; hooks and the validation always run; a setup
# failure (configuration, manifest, skills lock, hook scripts) always ends
# it.
#
# Codes besides the skill layout codes of cli/lib/skills.sh:
#   official-binary-failed  a missing or older binary (check), a failed
#                           install
#   hook-failed             a hook exited non-zero or cannot run
#   missing-command         a checks.commands or floor command is not on the
#                           user's PATH (user_path: without the CLI's own
#                           toolchain)
#   floor-not-met, floor-invalid
#   probes: the codes of cli/lib/probes.sh (missing-command,
#           expected-unreadable, version-mismatch, presence-failed,
#           features-failed, needle-missing) and probes-invalid
#   error                   any other refusal; failed: a step that exited
#                           without a finding
set -Eeuo pipefail

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"
# shellcheck source=cli/lib/probes.sh
source "$DOTSTEWARD_LIB/probes.sh"
# shellcheck source=cli/lib/skills.sh
source "$DOTSTEWARD_LIB/skills.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward agents install|check --profile PROFILE [--generation PATH]
                                        [--keep-going] [--json]

install makes the agent tools and the skill layout of PROFILE match the
instance: official-binary components, the canonical skill root
~/.agents/skills with its entries and link-root links, copies of missing
instance skills, refreshed drifted copies (backed up first), removed
dangling skill links and the agents hooks; then it validates. check runs
the same steps without changing anything and fails on the first
difference.

  --profile PROFILE   a profile of the instance (required)
  --generation PATH   a built Home Manager generation: its manifest, its
                      framework skill sources and its home-path/bin first on
                      PATH for the validation; default: the active
                      generation, else the instance's manifest mirror
  --keep-going        record each failure and go on with the steps that do
                      not depend on it
  --json              print { "result": "passed|failed", "findings": [ {
                      "step", "path", "code", "message" } ] } on standard
                      output; logs go to standard error

Exit status: 0 done or verified, 1 refusal or failed check, or the status
of a failed command.
EOF
}

mode=''
profile=''
generation=''
keep_going=0
json=0
while (($#)); do
  case $1 in
    install | check)
      [[ -z $mode ]] || die "agents: only one of install or check is allowed"
      mode=$1
      shift
      ;;
    --profile | --generation)
      if (($# < 2)) || [[ -z $2 ]]; then
        die "agents: $1 requires a value"
      fi
      if [[ $1 == --profile ]]; then
        profile=$2
      else
        generation=$2
      fi
      shift 2
      ;;
    --profile=*)
      profile=${1#--profile=}
      shift
      ;;
    --generation=*)
      generation=${1#--generation=}
      shift
      ;;
    --keep-going)
      keep_going=1
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "agents: unknown option: $1" ;;
    *) die "agents: unknown subcommand: $1 (expected install or check)" ;;
  esac
done
[[ -n $mode ]] || die "agents: install or check is required"
[[ -n $profile ]] || die "agents: --profile is required"
if [[ -n $generation ]]; then
  [[ -d $generation ]] || die "agents: generation not found: $generation"
  generation=$(cd -P -- "$generation" && pwd)
fi
check_only=0
[[ $mode == check ]] && check_only=1

# --- Findings -------------------------------------------------------------

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-agents.XXXXXX")
SKILLS_FINDINGS_FILE=$work_dir/findings.jsonl
: >"$SKILLS_FINDINGS_FILE"
SKILLS_KEEP_GOING=$keep_going
SKILLS_STEP=setup
failed=0

_agents_exit() {
  local status=$?
  if ((json)); then
    jq -s --argjson status "$status" \
      '{ result: (if $status == 0 and length == 0 then "passed" else "failed" end), findings: . }' \
      "$SKILLS_FINDINGS_FILE" >&3 || true
  fi
  cleanup_temp_dir "$work_dir"
  exit "$status"
}
trap _agents_exit EXIT

# Every error from here on is a finding: library code reports through die.
die() {
  skills_finding "${SKILLS_DIE_CODE:-error}" "${SKILLS_DIE_PATH:-}" "$*"
  exit 1
}

# With --json, everything but the report goes to standard error.
if ((json)); then
  exec 3>&1 1>&2
fi

_agents_findings_count() {
  local count
  count=$(wc -l <"$SKILLS_FINDINGS_FILE")
  printf '%s\n' "$((count))"
}

# _agents_unit STEP FUNCTION [ARG...]: runs one unit of work in a subshell
# (with errexit, whatever the caller's context). A failure without a
# finding gets a generic one. Fail-fast: the command ends with the unit's
# status; keep-going: AGENTS_LAST_STATUS holds it.
AGENTS_LAST_STATUS=0
_agents_unit() {
  local step=$1 before status
  shift
  before=$(_agents_findings_count)
  set +e
  (
    set -e
    SKILLS_STEP=$step
    SKILLS_DIE_CODE='error'
    SKILLS_DIE_PATH=''
    "$@"
  )
  status=$?
  set -e
  AGENTS_LAST_STATUS=$status
  ((status != 0)) || return 0
  if (($(_agents_findings_count) == before)); then
    SKILLS_STEP=$step skills_finding failed "" "step $step failed (exit $status)"
  fi
  ((keep_going)) || exit "$status"
  failed=1
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
for tool in find jq realpath sha256sum sort xargs; do
  require_command "$tool"
done

explicit_generation=$generation
if [[ -z $generation ]]; then
  generation=$(skills_active_generation)
fi
methods_manifest_load "$generation"
skills_init "$profile" "$check_only" "$generation"
skills_validate_lock

active_text=$(methods_components "$profile")
mapfile -t active < <(grep -v '^$' <<<"$active_text" || true)
active_json=$(printf '%s\n' "${active[@]}" | grep -v '^$' | jq -R . | jq -cs .) || active_json='[]'

# _agents_check_hooks: the checks.agents hooks to run, like methods_hooks.
_agents_check_hooks() {
  jq -c --arg profile "$profile" --argjson active "$active_json" '
    [(.checks.agents // []) | to_entries[]
      | .value as $hook
      | select($active | index($hook.component))
      | select($hook.profiles == null or ($hook.profiles | index($profile)))
      | { key: [($active | index($hook.component)), .key], hook: ($hook + { list: "checks.agents" }) }]
    | sort_by(.key)[] | .hook' <<<"$DS_MANIFEST_JSON"
}

# _agents_hooks LIST: the hooks of a phase list, or checks.agents for
# "agents".
_agents_hooks() {
  if [[ $1 == agents ]]; then
    _agents_check_hooks
  else
    methods_hooks "$1" "$profile"
  fi
}

# Every hook script resolves before anything runs.
declare -A hook_lists=()
for list in agents_install agents_migrate agents_post agents; do
  hooks_text=$(_agents_hooks "$list")
  mapfile -t hooks < <(grep -v '^$' <<<"$hooks_text" || true)
  for hook in "${hooks[@]}"; do
    methods_hook_path "$hook" >/dev/null
  done
  hook_lists[$list]=$hooks_text
done

# --- Units ----------------------------------------------------------------

_agents_official_binary() {
  local name=$1 status=0
  SKILLS_DIE_CODE='official-binary-failed'
  SKILLS_DIE_PATH=$name
  if ((check_only)); then
    methods_check "$name" "$profile" || status=$?
    ((status == 0)) || skills_fail official-binary-failed "$name" "$name (official-binary): $METHODS_DETAIL"
  else
    methods_official_binary_install "$name"
    if [[ $METHODS_STATUS == installed ]]; then
      log "$name (official-binary): installed $METHODS_DETAIL"
    fi
  fi
}

_agents_run_hook() {
  local hook=$1 component name status=0
  component=$(jq -r '.component' <<<"$hook")
  name=$(jq -r '.name' <<<"$hook")
  SKILLS_DIE_CODE='hook-failed'
  SKILLS_DIE_PATH=$component/$name
  methods_run_hook "$hook" "$profile" "$check_only" || status=$?
  ((status == 0)) ||
    skills_fail hook-failed "$component/$name" "component $component hook $name failed (exit $status)"
}

# _agents_run_hooks LIST STEP
_agents_run_hooks() {
  local hook
  local -a hooks=()
  mapfile -t hooks < <(grep -v '^$' <<<"${hook_lists[$1]}" || true)
  for hook in "${hooks[@]}"; do
    _agents_unit "$2" _agents_run_hook "$hook"
  done
}

# _agents_selected KEY: the entries of checks.KEY of the active components,
# in component order, then declaration order.
_agents_selected() {
  jq -c --arg key "$1" --argjson active "$active_json" '
    [(.checks[$key] // []) | to_entries[]
      | .value as $entry
      | select($active | index($entry.component))
      | { key: [($active | index($entry.component)), .key], entry: $entry }]
    | sort_by(.key)[] | .entry' <<<"$DS_MANIFEST_JSON"
}

_agents_commands() {
  local command search unit_failed=0
  local -A seen=()
  search=$(user_path)
  while IFS= read -r command; do
    [[ -n $command && -z ${seen[$command]:-} ]] || continue
    seen[$command]=1
    if ! PATH=$search command -v -- "$command" >/dev/null 2>&1; then
      skills_finding missing-command "$command" "required command not found: $command"
      ((keep_going)) || exit 1
      unit_failed=1
    fi
  done < <(_agents_selected commands | jq -r '.command')
  ((unit_failed == 0)) || exit 1
}

# _agents_floor_minimum MINIMUM COMPONENT: a version literal (starting with
# a digit, or v and a digit), else a lock path of versions.lock.json whose
# value is a version string or an entry with minimum_version or version.
_agents_floor_minimum() {
  local minimum=$1 value
  if [[ $minimum =~ ^v?[0-9] ]]; then
    printf '%s\n' "$minimum"
    return 0
  fi
  value=$(methods_lock_get "$minimum" "$2")
  value=$(jq -r 'if type == "string" then .
    elif type == "object" then ([.minimum_version, .version] | map(strings | select(length > 0)) | first // empty)
    else empty end' <<<"$value")
  [[ -n $value ]] ||
    skills_fail floor-invalid "$minimum" "${DS_PINS_VERSIONS_LOCK##*/} $minimum is not a version (a string, or an entry with minimum_version or version)"
  printf '%s\n' "$value"
}

_agents_floors() {
  local floor command component compare minimum output found ok search timeout_command unit_failed=0
  local -a argv=()
  SKILLS_DIE_CODE='floor-invalid'
  search=$(user_path)
  timeout_command=$(command -v timeout) || die "required command not found: timeout"
  while IFS= read -r floor; do
    [[ -n $floor ]] || continue
    command=$(jq -r '.command' <<<"$floor")
    component=$(jq -r '.component' <<<"$floor")
    compare=$(jq -r '.compare // "semver"' <<<"$floor")
    mapfile -t argv < <(jq -r '(.argv // ["--version"])[]' <<<"$floor")
    SKILLS_DIE_PATH=$command
    minimum=$(_agents_floor_minimum "$(jq -r '.minimum' <<<"$floor")" "$component")
    if ! PATH=$search command -v -- "$command" >/dev/null 2>&1; then
      skills_finding missing-command "$command" "required command not found: $command"
      ((keep_going)) || exit 1
      unit_failed=1
      continue
    fi
    output=$(PATH=$search "$timeout_command" 60 "$command" "${argv[@]}" </dev/null 2>&1) || true
    found=$(methods_extract_version "$output") || found=''
    ok=0
    case $compare in
      dpkg)
        if ! command -v dpkg >/dev/null 2>&1; then
          skills_finding missing-command dpkg "required command not found: dpkg (floor of $command)"
          ((keep_going)) || exit 1
          unit_failed=1
          continue
        fi
        if [[ -n $found ]] && dpkg --compare-versions "$found" ge "$minimum"; then
          ok=1
        fi
        ;;
      semver)
        if methods_version_at_least "$found" "$minimum"; then
          ok=1
        fi
        ;;
      *) skills_fail floor-invalid "$command" "unknown floor comparison for $command: $compare" ;;
    esac
    if ((!ok)); then
      skills_finding floor-not-met "$command" "$command $minimum or newer is required (found ${found:-no version})"
      ((keep_going)) || exit 1
      unit_failed=1
    fi
  done < <(_agents_selected floors)
  ((unit_failed == 0)) || exit 1
}

_agents_probes() {
  local status=0 i
  SKILLS_DIE_CODE='probes-invalid'
  DS_PROBES_KEEP_GOING=1 run_cli_probes "$DS_MANIFEST_FILE" "$profile" "$probe_prefix" || status=$?
  ((status != 0)) || return 0
  for i in "${!DS_PROBES_FAILURES[@]}"; do
    skills_finding "${DS_PROBES_FAILURE_CODES[i]}" "${DS_PROBES_FAILURE_COMMANDS[i]}" "${DS_PROBES_FAILURES[i]}"
    ((keep_going)) || exit 1
  done
  exit 1
}

# --- Phases ---------------------------------------------------------------

# 1. User-level official binaries, then the agentsInstall hooks.
for name in "${active[@]}"; do
  [[ -n $name && $(methods_component_method "$name") == official-binary ]] || continue
  _agents_unit official-binary _agents_official_binary "$name"
done
_agents_run_hooks agents_install agents-install

# 2. Layout; 3. skills; 4. sweep. The skills and the sweep need the layout.
_agents_unit layout skills_ensure_layout
if ((AGENTS_LAST_STATUS == 0)); then
  framework_text=$(skills_framework_entries)
  mapfile -t framework_entries < <(grep -v '^$' <<<"$framework_text" || true)
  for entry in "${framework_entries[@]}"; do
    _agents_unit framework-skills skills_process_framework "$(jq -r '.name' <<<"$entry")" "$(jq -c '.entry' <<<"$entry")"
  done
  instance_text=$(skills_instance_entries)
  mapfile -t instance_entries < <(grep -v '^$' <<<"$instance_text" || true)
  for entry in "${instance_entries[@]}"; do
    _agents_unit skills skills_process_instance "$entry"
  done
  _agents_unit sweep skills_sweep
fi

# 5, 6. Migrations and post hooks.
_agents_run_hooks agents_migrate agents-migrate
_agents_run_hooks agents_post agents-post

# 7. Validation, with a built generation's commands first on PATH.
probe_prefix=''
if [[ -n $explicit_generation ]]; then
  probe_prefix=$generation/home-path/bin
  export PATH="$probe_prefix:$PATH"
fi
_agents_unit commands _agents_commands
_agents_unit floors _agents_floors
_agents_unit probes _agents_probes
_agents_run_hooks agents agents-checks

if ((failed)); then
  printf '[dotsteward] ERROR: agents %s failed: %s findings\n' "$mode" "$(_agents_findings_count)" >&2
  exit 1
fi
if ((check_only)); then
  log "agent tools and skills verified (profile $profile)"
else
  log "agent tools and skills installed (profile $profile)"
fi
