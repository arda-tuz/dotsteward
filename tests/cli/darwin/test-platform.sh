# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # bash -c scripts are single-quoted on purpose
# cli/lib/platform-darwin.sh: lib.sh loads it on darwin; the platform
# interface of platform-linux.sh (os id and version from sw_vers, the shells
# file, the login shell from the user database or dscl, set with dscl), the
# Xcode Command Line Tools check and the bundle version of an application.
# shellcheck source=tests/cli/darwin/helpers.sh
source "$DS_REPO_ROOT/tests/cli/darwin/helpers.sh"

# --- Loading ----------------------------------------------------------------
[[ -f $darwin_lib_dir/platform-darwin.sh ]] || ds_fail "cli/lib/platform-darwin.sh does not exist"
# shellcheck source=cli/lib/lib.sh
source "$darwin_lib_dir/lib.sh"
for function in platform_os_id platform_os_version platform_architecture platform_shells_file \
  platform_shells_contains platform_shells_add platform_shells_remove platform_login_shell \
  platform_set_login_shell platform_app_archive_install platform_app_archive_check \
  sw_vers_value xcode_clt_installed require_xcode_clt app_bundle_version; do
  declare -F "$function" >/dev/null || ds_fail "lib.sh did not load $function on darwin"
done
# The Linux helpers stay Linux-only, and the darwin ones darwin-only.
for function in os_release_value dpkg_installed apt_install package_provides; do
  ! declare -F "$function" >/dev/null || ds_fail "$function is defined on darwin"
done
assert_exit 1 env DOTSTEWARD_PLATFORM=linux bash -c 'source "$1" && declare -F xcode_clt_installed' _ "$darwin_lib_dir/lib.sh"
assert_exit 1 env DOTSTEWARD_PLATFORM=linux bash -c 'source "$1" && declare -F platform_app_archive_install' _ "$darwin_lib_dir/lib.sh"
# Sourcing the platform file alone also brings lib.sh.
assert_exit 0 bash -c 'source "$1" && declare -F die && declare -F xcode_clt_installed' _ "$darwin_lib_dir/platform-darwin.sh"
# Sourcing it runs none of the macOS tools.
ds_use_stubs sw_vers dscl xcode-select sudo
: >"$DS_CALL_LOG"
assert_exit 0 bash -c 'source "$1"' _ "$darwin_lib_dir/lib.sh"
assert_calls

# --- OS facts ---------------------------------------------------------------
# The harness points DOTSTEWARD_SW_VERS at a synthetic sw_vers (15.0).
assert_eq macos "$(platform_os_id)"
assert_eq 15.0 "$(platform_os_version)"
assert_eq "$(uname -m)" "$(platform_architecture)"
assert_eq 15.0 "$(sw_vers_value productVersion)"
assert_eq macOS "$(sw_vers_value productName)"
assert_eq 24A335 "$(sw_vers_value buildVersion)"
assert_exit 1 sw_vers_value 'bad key'
assert_eq "[dotsteward] ERROR: sw_vers_value: invalid key: bad key" "$DS_STDERR"
# Without the injection point the sw_vers command answers.
ds_use_stubs sw_vers
ds_stub_set sw_vers product-version 14.6.1
: >"$DS_CALL_LOG"
assert_eq 14.6.1 "$(unset DOTSTEWARD_SW_VERS; platform_os_version)"
assert_calls "sw_vers -productVersion"
# An unreadable version is "unknown", as in the preflight document.
assert_eq unknown "$(DOTSTEWARD_SW_VERS=/nonexistent/sw_vers platform_os_version)"
assert_eq macos "$(DOTSTEWARD_SW_VERS=/nonexistent/sw_vers platform_os_id)"

# --- Xcode Command Line Tools -------------------------------------------------
ds_use_stubs xcode-select
xcode_clt_installed || ds_fail "the Command Line Tools are installed"
ds_stub_set xcode-select installed 0
! xcode_clt_installed || ds_fail "the Command Line Tools are missing"
assert_exit 1 require_xcode_clt
assert_eq "[dotsteward] ERROR: the Xcode Command Line Tools are not installed; run 'xcode-select --install', finish the installation, then run the command again" \
  "$DS_STDERR"
assert_eq "" "$(ds_calls_of xcode-select | grep -v -- ' -p$' || true)" "only checked, never installed"
ds_stub_set xcode-select installed 1
assert_exit 0 require_xcode_clt
# Without xcode-select (a host that is not a Mac) they are not installed.
rm -f -- "$DS_TEST_ROOT/bin/xcode-select"
hash -r
if ! command -v xcode-select >/dev/null 2>&1; then
  ! xcode_clt_installed || ds_fail "no xcode-select, no Command Line Tools"
fi

# --- Shells file and login shell ----------------------------------------------
ds_use_stubs sudo dscl
shells=$DOTSTEWARD_ETC_SHELLS
assert_eq "$shells" "$(platform_shells_file)"
assert_eq /etc/shells "$(unset DOTSTEWARD_ETC_SHELLS; platform_shells_file)"
platform_shells_contains /bin/bash || ds_fail "/bin/bash is listed"
! platform_shells_contains /bin/zsh || ds_fail "/bin/zsh is not listed"
! platform_shells_contains /bin || ds_fail "prefixes do not count"

# The user database of DOTSTEWARD_PASSWD_CMD answers first (as on Linux).
: >"$DS_CALL_LOG"
assert_eq /bin/bash "$(platform_login_shell)"
ds_passwd_set example /bin/zsh
assert_eq /bin/zsh "$(platform_login_shell example)"
assert_calls
# Without it, dscl's UserShell attribute.
assert_eq /bin/zsh "$(unset DOTSTEWARD_PASSWD_CMD; platform_login_shell example)"
assert_calls "dscl . -read /Users/example UserShell"
no_user_shell() {
  unset DOTSTEWARD_PASSWD_CMD
  platform_login_shell no-such-user
}
assert_exit 1 no_user_shell
assert_eq "[dotsteward] ERROR: cannot read the login shell of no-such-user" "$DS_STDERR"
# A shell path with a space survives the attribute parsing.
ds_passwd_set example "/opt/my shells/zsh"
assert_eq "/opt/my shells/zsh" "$(unset DOTSTEWARD_PASSWD_CMD; platform_login_shell example)"

: >"$DS_CALL_LOG"
platform_shells_add "$HOME/.nix-profile/bin/zsh"
assert_eq "$HOME/.nix-profile/bin/zsh" "$(tail -n 1 "$shells")"
assert_calls "sudo tee -a $shells"
: >"$DS_CALL_LOG"
before=$(<"$shells")
printf '%s\n' /nix/store/x-zsh/bin/zsh >>"$shells"
platform_shells_remove /nix/store/x-zsh/bin/zsh
assert_eq "$before" "$(<"$shells")"
assert_file_mode "$shells" 644
# root's group on macOS is wheel.
[[ $(ds_calls_of sudo) == "sudo install -o root -g wheel -m 0644 $TMPDIR/dotsteward-shells."*" $shells" ]] ||
  ds_fail "unexpected install call: $(ds_calls_of sudo)"
[[ -z $(find "$TMPDIR" -name 'dotsteward-shells.*') ]] || ds_fail "temporary shells file left behind"

# The login shell is set through the directory service.
: >"$DS_CALL_LOG"
platform_set_login_shell "$HOME/.nix-profile/bin/zsh"
assert_calls "sudo dscl . -create /Users/$USER UserShell $HOME/.nix-profile/bin/zsh" \
  "dscl . -create /Users/$USER UserShell $HOME/.nix-profile/bin/zsh"
assert_eq "$HOME/.nix-profile/bin/zsh" "$(platform_login_shell)"
: >"$DS_CALL_LOG"
platform_set_login_shell /bin/zsh example
assert_calls "sudo dscl . -create /Users/example UserShell /bin/zsh" "dscl . -create /Users/example UserShell /bin/zsh"
assert_eq /bin/zsh "$(ds_passwd_field example 7)"
# A refused sudo fails the change.
ds_stub_route sudo '*' --exit 1 --stderr 'sudo: a password is required'
assert_exit 1 platform_set_login_shell /bin/bash example
assert_eq /bin/zsh "$(ds_passwd_field example 7)"
ds_stub_clear_routes sudo

# --- Bundle version -----------------------------------------------------------
apps=$DS_TEST_ROOT/apps
make_bundle "$apps" "Example App.app" 1.2.3
assert_eq 1.2.3 "$(app_bundle_version "$apps/Example App.app")"
make_bundle "$apps" "Binary.app" 2.0.1 binary
assert_eq 2.0.1 "$(app_bundle_version "$apps/Binary.app")"
make_bundle "$apps" "Bare.app" 1.0 none
assert_eq "" "$(app_bundle_version "$apps/Bare.app")"
assert_eq "" "$(app_bundle_version "$apps/Missing.app")"
printf 'not a property list\n' >"$apps/Bare.app/Contents/Info.plist"
assert_eq "" "$(app_bundle_version "$apps/Bare.app")"
python3 -I -c 'import plistlib, sys; plistlib.dump(["a list"], open(sys.argv[1], "wb"))' "$apps/Bare.app/Contents/Info.plist"
assert_eq "" "$(app_bundle_version "$apps/Bare.app")"
python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleShortVersionString": 7}, open(sys.argv[1], "wb"))' \
  "$apps/Bare.app/Contents/Info.plist"
assert_eq "" "$(app_bundle_version "$apps/Bare.app")"
python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleShortVersionString": " 3.4.5\n"}, open(sys.argv[1], "wb"))' \
  "$apps/Bare.app/Contents/Info.plist"
assert_eq 3.4.5 "$(app_bundle_version "$apps/Bare.app")"
# A symlinked Info.plist is not read.
ln -sfn "$apps/Binary.app/Contents/Info.plist" "$apps/Bare.app/Contents/Info.plist"
assert_eq "" "$(app_bundle_version "$apps/Bare.app")"
