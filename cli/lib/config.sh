# shellcheck shell=bash
# The instance configuration for bash (SPEC 4.1, 6.1).
#
# Source after lib.sh. config_load runs the Python reader
# (cli/python/dotsteward_cli/config.py) and evaluates its DS_* declarations;
# the reader validates workstation.toml exactly like lib/config.nix and
# prints every problem as an "[dotsteward] ERROR:" line, after which
# config_load exits 1.
#
#   config_load [DIR]          discovers the instance (DIR, else
#                              DOTSTEWARD_INSTANCE, else DOTFILES_ROOT when its
#                              configuration sets compat.legacy_env, else the
#                              nearest workstation.toml above the working
#                              directory), loads the DS_* variables, exports
#                              DOTSTEWARD_INSTANCE and sets (without
#                              exporting) DOTSTEWARD_STATE_ROOT for lib.sh
#   config_query [JQ_OPTION...] FILTER
#                              jq -r over the resolved configuration
#   config_instance_path PATH  PATH below the instance root (absolute paths
#                              unchanged)
#   config_profile_mode PROFILE
#                              fresh or adopt
#   config_component_active NAME PROFILE
#                              status 0 when the component is enabled and
#                              PROFILE is in its profiles (or it has none)
# The query helpers read DS_CONFIG_JSON, which is exported, so they also work
# in child processes (component hooks) of a command that loaded the
# configuration.
#
# Variables. Scalars are exported; null is the empty string, booleans are
# true or false. Paths marked "expanded" have ~/ and ${VAR:-default} expanded
# with the runtime environment; instance paths stay relative to
# DS_INSTANCE_ROOT.
#   DS_CONFIG_FILE, DS_INSTANCE_ROOT     the file and the instance root
#   DS_RUNTIME_PLATFORM                  linux or darwin (DOTSTEWARD_PLATFORM,
#                                        else the running system)
#   DS_CONFIG_JSON                       the resolved configuration (the value
#                                        of lib/config.nix; nothing expanded)
#   DS_IDENTITY_USERNAME, DS_IDENTITY_HOME, DS_IDENTITY_DARWIN_HOME
#   DS_INSTANCE_NAME, DS_INSTANCE_REMOTE, DS_INSTANCE_BRANCH,
#   DS_INSTANCE_CHECKOUT (expanded)
#   DS_STATE_ROOT                        DOTSTEWARD_STATE_ROOT, else
#                                        DOTFILES_STATE_ROOT with
#                                        compat.legacy_env, else state.root
#                                        (expanded)
#   DS_NIX_PRIMARY_SYSTEM, DS_NIX_ALLOW_UNFREE, DS_NIX_STATE_VERSION
#   DS_PROFILES_DEFAULT, DS_PROFILES_CHECK, DS_PROFILES_BOOTSTRAP
#   DS_PLATFORM_LINUX_OS_ID, DS_PLATFORM_LINUX_OS_VERSION,
#   DS_PLATFORM_LINUX_ARCHITECTURE, DS_PLATFORM_LINUX_DESKTOP_CONTAINS,
#   DS_PLATFORM_DARWIN_MIN_VERSION, DS_PLATFORM_DARWIN_ARCHITECTURE
#   DS_GATE_NIX_MAX_JOBS, DS_GATE_NIX_CORES, DS_GATE_MIN_FREE_GIB,
#   DS_GATE_CACHE_URL                    the parallelism derived from the
#                                        machine when unset, after the
#                                        DOTSTEWARD_NIX_MAX_JOBS,
#                                        DOTSTEWARD_NIX_CORES,
#                                        DOTSTEWARD_MIN_FREE_GB and
#                                        DOTSTEWARD_CACHE_URL overrides (and
#                                        their DOTFILES_* fallbacks with
#                                        compat.legacy_env)
#   DS_GATE_PREPARE_WARN_FREE_GIB
#   DS_COMMIT_UPDATE_SUBJECT, DS_COMMIT_SETTINGS_SUBJECT,
#   DS_COMMIT_UPGRADE_SUBJECT
#   DS_SETTINGS_BUFFER_DIR, DS_SETTINGS_PUBLISHED_REF
#   DS_SKILLS_LOCK, DS_SKILLS_VENDOR_DIR, DS_SKILLS_HM_ROOT
#   DS_PINS_VERSIONS_LOCK, DS_PINS_APT_ARCH
#   DS_PRIVACY_DENYLIST                  expanded; relative to the instance
#                                        root when relative
#   DS_PRIVACY_FILE_RULES_JSON           privacy.file_rules as JSON
#   DS_AGENT_RULES_SOURCE
#   DS_UPSTREAM_CONTRIBUTE, DS_UPSTREAM_FORK, DS_UPSTREAM_PR_TO_UPSTREAM,
#   DS_UPSTREAM_LOCAL_CLONE (expanded)
#   DS_COMPAT_LEGACY_ENV, DS_COMPAT_LEGACY_BACKUP_LAYOUT,
#   DS_COMPAT_REPO_OWNED_REVISION, DS_COMPAT_HOST_INPUT
# Indexed arrays:
#   DS_NIX_SYSTEMS, DS_PROFILES_NAMES, DS_PLATFORM_LINUX_DETECTORS,
#   DS_GATE_STATIC, DS_GATE_UPDATE_ALLOWLIST, DS_COMPONENTS_ORDER (hook and
#   check order), DS_COMPONENTS_ENABLED (the enabled ones, in that order),
#   DS_SKILLS_INSTALLER (empty: the native copy),
#   DS_PINS_EXCLUDED_FLAKE_INPUTS, DS_PRIVACY_FORBIDDEN_PATHS
# Associative arrays:
#   DS_PROFILE_MODE[profile]             fresh or adopt
#   DS_COMPONENT_ENABLE[name]            true or false
#   DS_COMPONENT_SOURCE[name]            catalog or instance
#   DS_COMPONENT_METHOD[name]            the method on DS_RUNTIME_PLATFORM
#                                        (method_by_platform, then method;
#                                        empty: the component's default)
#   DS_COMPONENT_PROFILES[name]          space-separated profiles (empty:
#                                        every profile)
#   DS_SKILLS_OVERLAYS[skill]            the given overlays plus
#                                        agent/overlays/<skill>.md where it
#                                        exists
#   DS_PINS_NIXPKGS_VERSIONS[key], DS_PROTECTED[path],
#   DS_COMPAT_CHECK_ALIASES[name]

_DS_CONFIG_PYTHON_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../python" && pwd -P)

config_load() {
  (($# <= 1)) || die "usage: config_load [DIR]"
  local output line name args=()
  if (($#)); then
    args=(--instance "$1")
  fi
  # The reader prints its own error lines.
  output=$(PYTHONPATH=$_DS_CONFIG_PYTHON_DIR PYTHONDONTWRITEBYTECODE=1 \
    python3 -s -P -m dotsteward_cli.config "${args[@]}" export) || exit 1
  # A name keeps its kind (scalar, indexed or associative array) across
  # loads only when it is declared afresh.
  while IFS= read -r line; do
    name=${line#declare -g? }
    unset -v "${name%%=*}"
  done <<<"$output"
  eval "$output"
  export DOTSTEWARD_INSTANCE=$DS_INSTANCE_ROOT
  # Not exported: a child process that loads another instance must not
  # inherit this one's state root as an override.
  # shellcheck disable=SC2034 # read by state_root in lib.sh
  DOTSTEWARD_STATE_ROOT=$DS_STATE_ROOT
}

_config_json() {
  [[ -n ${DS_CONFIG_JSON:-} ]] || die "${FUNCNAME[1]}: the instance configuration is not loaded"
  printf '%s\n' "$DS_CONFIG_JSON"
}

config_query() {
  (($#)) || die "usage: config_query [JQ_OPTION...] FILTER"
  local json
  json=$(_config_json) || exit 1
  jq -r "$@" <<<"$json" || die "invalid configuration query: ${*: -1}"
}

config_instance_path() {
  (($# == 1)) || die "usage: config_instance_path PATH"
  [[ -n ${DS_INSTANCE_ROOT:-} ]] || die "config_instance_path: the instance configuration is not loaded"
  if [[ $1 == /* ]]; then
    printf '%s\n' "$1"
  else
    printf '%s/%s\n' "$DS_INSTANCE_ROOT" "$1"
  fi
}

config_profile_mode() {
  (($# == 1)) || die "usage: config_profile_mode PROFILE"
  local json mode
  json=$(_config_json) || exit 1
  mode=$(jq -r --arg p "$1" \
    'if any(.profiles.names[]; . == $p) then .profiles[$p].mode else "" end' <<<"$json")
  [[ -n $mode ]] || die "unknown profile: $1"
  printf '%s\n' "$mode"
}

config_component_active() {
  (($# == 2)) || die "usage: config_component_active NAME PROFILE"
  local json state
  json=$(_config_json) || exit 1
  state=$(jq -r --arg n "$1" --arg p "$2" '
    .components[$n] as $c
    | if ($c | type) != "object" then "unknown"
      elif $c.enable != true then "off"
      elif $c.profiles == null or any($c.profiles[]; . == $p) then "on"
      else "off" end' <<<"$json")
  case $state in
    on) return 0 ;;
    off) return 1 ;;
    *) die "unknown component: $1" ;;
  esac
}
