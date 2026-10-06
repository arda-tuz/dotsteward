# shellcheck shell=bash
# Helpers of the host tests (tests/host): scripts that use the real Nix of
# the machine, in the temporary root of tests/lib/harness.sh (temporary HOME,
# TMPDIR, git identity and DOTSTEWARD_STATE_ROOT, synthetic USER). They build
# into the Nix store and never activate a generation (SPEC 12.5). A host test
# sources this file and calls host_e2e_init first:
#
#   host_e2e_init FILE [ARG...]   --help prints FILE's header; otherwise runs
#                                 FILE again under `timeout` (DS_HOST_TIMEOUT
#                                 seconds, default 3600) and then sets up the
#                                 harness; refuses without nix, git or jq
#   host_log MESSAGE              a progress line on standard error
#   host_step TITLE COMMAND...    COMMAND as a titled step (a log group on
#                                 GitHub Actions) with its duration
#   host_nix ARG...               nix with the flakes features enabled
#   host_framework_cli ARG...     the dotsteward CLI of the checkout under
#                                 test (nix run DS_HOST_FRAMEWORK_URL)
#   host_instance_cli ARG...      the launcher of ~/workstation
#   host_built_activation         the activation package the last rebuild
#                                 recorded in the state root
#   host_lmf ARG...               the local-maintained-files alias of that
#                                 generation (its baked defaults)
#   host_assert_not_activated DIR
#                                 DIR holds no link into the Nix store and no
#                                 Home Manager or Nix profile state
#   host_assert_real_profiles_unchanged
#                                 the invoking user's Home Manager and Nix
#                                 profile state equals the snapshot taken by
#                                 host_e2e_init
#
# DS_HOST_FRAMEWORK_URL: the framework flake reference used by init and the
# instance (default path:<checkout>; a shallow CI checkout cannot be a
# git+file input).

_HOST_LIB_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

_host_die() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
  exit 1
}

# _host_profiles_snapshot USER HOME: one line per entry of the paths where
# Home Manager and Nix keep a user's generations and profiles.
_host_profiles_snapshot() {
  local user=$1 home=$2 path
  for path in "$home/.local/state/nix/profiles" "$home/.local/state/home-manager" \
    "/nix/var/nix/profiles/per-user/$user" "$home/.nix-profile"; do
    if [[ -e $path || -L $path ]]; then
      find "$path" -maxdepth 1 -printf '%p %y %l %T@\n' 2>/dev/null | LC_ALL=C sort
    else
      printf 'absent %s\n' "$path"
    fi
  done
}

host_e2e_init() {
  (($# >= 1)) || _host_die "host_e2e_init: usage: host_e2e_init FILE [ARG...]"
  local file=$1 budget nix_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  shift
  case ${1:-} in
    -h | --help)
      sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "$file"
      exit 0
      ;;
  esac
  (($# == 0)) || _host_die "usage: $(basename -- "$file") [--help]"

  if [[ -z ${_DS_HOST_UNDER_TIMEOUT:-} ]]; then
    budget=${DS_HOST_TIMEOUT:-3600}
    [[ $budget =~ ^[1-9][0-9]*$ ]] || _host_die "DS_HOST_TIMEOUT must be a positive number of seconds: $budget"
    command -v timeout >/dev/null 2>&1 || _host_die "the host tests need timeout (coreutils)"
    # Without --foreground, timeout signals the whole process group, so a
    # Nix build started by the test stops with it.
    export _DS_HOST_UNDER_TIMEOUT=1
    exec timeout --kill-after=60 "$budget" bash "$file"
  fi
  unset _DS_HOST_UNDER_TIMEOUT

  if ! command -v nix >/dev/null 2>&1 && [[ -r $nix_profile ]]; then
    # The profile script is not written for nounset.
    set +u
    # shellcheck source=/dev/null
    source "$nix_profile"
    set -u
  fi
  local tool
  for tool in nix git jq; do
    command -v "$tool" >/dev/null 2>&1 || _host_die "the host tests need $tool on PATH"
  done

  # Taken before the harness replaces HOME and USER.
  _HOST_REAL_USER=${USER:-$(id -un)}
  _HOST_REAL_HOME=$HOME
  _HOST_REAL_PROFILES=$(_host_profiles_snapshot "$_HOST_REAL_USER" "$_HOST_REAL_HOME")

  # shellcheck source=tests/lib/harness.sh
  source "$_HOST_LIB_DIR/../lib/harness.sh"
  # shellcheck source=tests/lib/assert.sh
  source "$_HOST_LIB_DIR/../lib/assert.sh"
  # shellcheck source=tests/lib/bare-remote.sh
  source "$_HOST_LIB_DIR/../lib/bare-remote.sh"
  ds_harness_init "$file"

  DS_HOST_FRAMEWORK_URL=${DS_HOST_FRAMEWORK_URL:-path:$DS_REPO_ROOT}
  export DS_HOST_FRAMEWORK_URL
  _HOST_STARTED=$SECONDS
}

host_log() {
  printf '[dotsteward] %s: %s\n' "$(basename -- "${DS_TEST_FILE:-host}" .sh)" "$*" >&2
}

host_step() {
  (($# >= 2)) || ds_fail "host_step: usage: host_step TITLE COMMAND [ARG...]"
  local title=$1 started=$SECONDS
  shift
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::group::%s\n' "$title"
  fi
  host_log "step: $title"
  "$@"
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::endgroup::\n'
  fi
  host_log "done in $((SECONDS - started))s (total $((SECONDS - _HOST_STARTED))s): $title"
}

host_nix() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}

host_framework_cli() {
  host_nix run "$DS_HOST_FRAMEWORK_URL#dotsteward" -- "$@"
}

host_instance_cli() {
  "$HOME/workstation/.dotsteward/cli.sh" "$@"
}

host_built_activation() {
  local record=$DOTSTEWARD_STATE_ROOT/current/last-built-activation
  [[ -f $record ]] || ds_fail "no build recorded: $record"
  printf '%s\n' "$(<"$record")"
}

host_lmf() {
  local activation
  activation=$(host_built_activation)
  "$activation/home-path/bin/local-maintained-files" "$@"
}

host_assert_not_activated() {
  (($# == 1)) || ds_fail "host_assert_not_activated: usage: host_assert_not_activated DIR"
  local dir=$1 links path
  links=$(find "$dir" -type l -lname '/nix/store/*' -print 2>/dev/null | LC_ALL=C sort)
  assert_eq "" "$links" "links into the Nix store in $dir (an activation)"
  for path in .local/state/home-manager .local/state/nix/profiles .nix-profile .config/home-manager; do
    [[ ! -e $dir/$path && ! -L $dir/$path ]] || ds_fail "Home Manager or Nix profile state in $dir: $path"
  done
}

host_assert_real_profiles_unchanged() {
  assert_eq "$_HOST_REAL_PROFILES" "$(_host_profiles_snapshot "$_HOST_REAL_USER" "$_HOST_REAL_HOME")" \
    "the profiles of the invoking user"
}
