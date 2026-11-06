# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # hook scripts and drivers are single-quoted on purpose
# The bash hook library is frozen as v1 (docs/hook-library.md), so the hooks
# in instances keep working: exactly the functions below come with
# $DOTSTEWARD_LIB/lib.sh on each platform and with config.sh, the methods
# engine keeps the functions hooks call, a real hook of an instance runs with
# the documented environment, and the page names every function. A new helper
# goes into the Python package (docs/python.md), not into this library: a
# test failure here means the change breaks hooks or grows a frozen interface.

library=$DS_REPO_ROOT/cli/lib
page=$DS_REPO_ROOT/docs/hook-library.md
[[ -f $page ]] || ds_fail "missing docs/hook-library.md"

lib_v1='backup_copy_of
backup_file_private
cleanup_temp_dir
current_platform
desktop_pin
die
directory_sha256
download_https
download_verified
ensure_private_dir
ensure_stable_login_shell
forbid_paths
git_net
install_asset
lock_value
log
nix_cmd
pin_value
platform_architecture
platform_login_shell
platform_os_id
platform_os_version
platform_set_login_shell
platform_shells_add
platform_shells_contains
platform_shells_file
platform_shells_remove
require_command
require_profile
require_safe_identity
sha256_file
source_nix_daemon
stable_zsh_path
state_root
timestamp_utc
user_login_zsh
user_path
user_run
warn'

linux_v1='apt_install
apt_update
deb_field
dpkg_installed
dpkg_version
dpkg_version_at_least
os_release_value
package_provides'

darwin_v1='app_bundle_version
platform_app_archive_check
platform_app_archive_install
require_xcode_clt
sw_vers_value
xcode_clt_installed'

config_v1='config_component_active
config_instance_path
config_load
config_profile_mode
config_query'

# The methods engine is the framework's own and may grow; these stay.
methods_v1='methods_check
methods_component
methods_component_method
methods_components
methods_extract_version
methods_hook_path
methods_hooks
methods_is_system_level
methods_lock_get
methods_manifest_load
methods_run_hook
methods_system
methods_validate
methods_version_at_least
methods_version_compare'

sorted() {
  printf '%s\n' "$@" | LC_ALL=C sort
}

# public_functions PLATFORM LIBRARY...: the public functions a hook on
# PLATFORM has after sourcing LIBRARY..., one per line.
public_functions() {
  local platform=$1
  shift
  env -u DOTSTEWARD_PLATFORM DOTSTEWARD_PLATFORM="$platform" DOTSTEWARD_LIB="$library" \
    bash --noprofile --norc -c '
      for name in "$@"; do
        source "$DOTSTEWARD_LIB/$name"
      done
      declare -F | cut -d" " -f3 | grep -v "^_" | LC_ALL=C sort
    ' bash "$@"
}

assert_eq "$(sorted "$lib_v1" "$linux_v1")" "$(public_functions linux lib.sh)" "the functions of lib.sh on Linux"
assert_eq "$(sorted "$lib_v1" "$darwin_v1")" "$(public_functions darwin lib.sh)" "the functions of lib.sh on darwin"
assert_eq "$(sorted "$lib_v1" "$linux_v1" "$config_v1")" "$(public_functions linux lib.sh config.sh)" \
  "the functions of lib.sh and config.sh"
methods=$(public_functions linux lib.sh config.sh methods.sh)
while IFS= read -r name; do
  grep -qxF -- "$name" <<<"$methods" || ds_fail "methods.sh lost $name"
done <<<"$methods_v1"

# Sourcing keeps turning on strict mode in the hook and prints nothing.
assert_eq 'errexit nounset pipefail errtrace' "$(
  DOTSTEWARD_LIB=$library bash --noprofile --norc -c '
    source "$DOTSTEWARD_LIB/lib.sh" >"$DS_TEST_ROOT/sourced" 2>&1
    [[ ! -s $DS_TEST_ROOT/sourced ]] || die "sourcing lib.sh printed something"
    for option in errexit nounset pipefail; do
      [[ -o $option ]] || die "$option is off"
    done
    [[ $- == *E* ]] || die "errtrace is off"
    printf "errexit nounset pipefail errtrace"
  '
)"

# The page names every function and environment variable.
for name in $lib_v1 $linux_v1 $darwin_v1 $config_v1 $methods_v1 DOTSTEWARD_LIB DOTSTEWARD_INSTANCE \
  DOTSTEWARD_STATE_ROOT DOTSTEWARD_PROFILE DOTSTEWARD_PROFILE_MODE DOTSTEWARD_PLATFORM DOTSTEWARD_COMPONENT \
  DOTSTEWARD_CHECK_ONLY DOTSTEWARD_ASSUME_YES; do
  grep -qF -- "\`$name" "$page" || ds_fail "docs/hook-library.md does not name $name"
done

# --- a real hook of an instance ---------------------------------------------------

# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"
ds_use_stubs sudo curl dpkg dpkg-query
ds_dpkg_installed example-term 2.1.0-1
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
lock_set desktop_packages.example-term '{"version": "2.1.0", "url": "https://example.invalid/term.deb"}'
lock_set agent_tools.example-cli '{"version": "3.0.0"}'
results=$DS_TEST_ROOT/hook-results
export HOOK_RESULTS=$results

# The helpers hooks in instances use most, the way they use them.
add_hook post_install example-app contract <<'HOOK'
source "$DOTSTEWARD_LIB/lib.sh"
{
  printf 'environment %s %s %s %s %s %s %s\n' "$DOTSTEWARD_COMPONENT" "$DOTSTEWARD_PROFILE" \
    "$DOTSTEWARD_PROFILE_MODE" "$DOTSTEWARD_PLATFORM" "$DOTSTEWARD_CHECK_ONLY" "$DOTSTEWARD_ASSUME_YES" \
    "$([[ $DOTSTEWARD_STATE_ROOT == "$(state_root)" ]] && printf same || printf different)"
  log "a line for the log"
  warn "a warning" 2>&1
  require_command bash
  [[ $(current_platform) == "$DOTSTEWARD_PLATFORM" ]] || die "current_platform"
  [[ $(timestamp_utc) =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "timestamp_utc: $(timestamp_utc)"
  private=$DOTSTEWARD_STATE_ROOT/contract/private
  ensure_private_dir "$private"
  printf 'private %s\n' "$(stat -c %a "$private")"
  printf 'content\n' >"$private/file"
  printf 'sha256 %s\n' "$(sha256_file "$private/file")"
  printf 'lock %s\n' "$(lock_value '.agent_tools["example-cli"].version')"
  printf 'pin %s\n' "$(pin_value example-term version)"
  printf 'desktop %s\n' "$(desktop_pin example-term url)"
  printf 'user_path %s\n' "$([[ -n $(user_path) ]] && printf set)"
  printf 'user_run %s\n' "$(user_run bash -c 'printf ran')"
  require_safe_identity
  dpkg_installed example-term && printf 'dpkg %s\n' "$(dpkg_version example-term)"
  ! dpkg_installed example-missing
  temp=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-contract.XXXXXX")
  cleanup_temp_dir "$temp"
  [[ ! -e $temp ]] || die "cleanup_temp_dir"
  backup_file_private "$private/file" "$DOTSTEWARD_STATE_ROOT/contract/backup"
} >"$HOOK_RESULTS"
HOOK
assert_exit 0 run_install --profile fresh
state=$DS_TEST_ROOT/state
expected_sha=$(printf 'content\n' | sha256sum | cut -d' ' -f1)
assert_eq "environment example-app fresh fresh linux 0 0 same
[dotsteward] a line for the log
[dotsteward] WARNING: a warning
private 700
sha256 $expected_sha
lock 3.0.0
pin 2.1.0
desktop https://example.invalid/term.deb
user_path set
user_run ran
dpkg 2.1.0-1" "$(<"$results")"
find "$state/contract/backup" -type f -name file | grep -q . || ds_fail "backup_file_private wrote no copy"
