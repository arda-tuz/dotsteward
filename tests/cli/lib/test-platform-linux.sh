# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ and backticks in expected values and bash -c scripts
# cli/lib/platform-linux.sh: os-release parsed (never sourced), the login
# shell primitives over the shells file and the user database, dpkg and APT
# helpers (package_provides included). lib.sh loads it on Linux.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

# lib.sh sources the platform file of the running platform when it exists.
declare -F platform_login_shell >/dev/null || ds_fail "lib.sh did not load platform-linux.sh"
assert_exit 0 in_lib_shell 'declare -F package_provides'
assert_exit 1 env DOTSTEWARD_PLATFORM=darwin bash -c 'source "$1" && declare -F package_provides' _ "$lib_dir/lib.sh"
# Sourcing the platform file alone also brings lib.sh.
assert_exit 0 bash -c 'source "$1" && declare -F die && declare -F dpkg_installed' _ "$lib_dir/platform-linux.sh"

# os-release: the fixture (DOTSTEWARD_OS_RELEASE).
assert_eq ubuntu "$(os_release_value ID)"
assert_eq 24.04 "$(os_release_value VERSION_ID)"
assert_eq "24.04 LTS (Noble Numbat)" "$(os_release_value VERSION)"
assert_eq "" "$(os_release_value MISSING)"
assert_eq fallback "$(os_release_value MISSING fallback)"
assert_eq ubuntu "$(platform_os_id)"
assert_eq 24.04 "$(platform_os_version)"
assert_eq "$(uname -m)" "$(platform_architecture)"
export DOTSTEWARD_OS_RELEASE=$DS_REPO_ROOT/tests/fixtures/common/os-release/debian-12
assert_eq debian "$(platform_os_id)"
# Quoting rules of os-release(5); the file is never executed.
# (A blank line of spaces and a trailing space come from printf, so this
# file keeps no trailing whitespace.)
cat >"$DS_TEST_ROOT/os-release" <<'OS'
# comment line
ID="quoted-id"
NAME='single $(touch pwned) quoted'
PRETTY_NAME="escaped \"quote\" \$dollar \\back \`tick\`"
VERSION_ID=bare
EVIL=$(touch pwned)
SPACED = "not an assignment"
ID_LIKE="a b"
EMPTY=
lower=case
OS
printf '  \nTRAILING="value" \n' >>"$DS_TEST_ROOT/os-release"
export DOTSTEWARD_OS_RELEASE=$DS_TEST_ROOT/os-release
assert_eq quoted-id "$(os_release_value ID)"
assert_eq 'single $(touch pwned) quoted' "$(os_release_value NAME)"
assert_eq 'escaped "quote" $dollar \back `tick`' "$(os_release_value PRETTY_NAME)"
assert_eq bare "$(os_release_value VERSION_ID)"
assert_eq '$(touch pwned)' "$(os_release_value EVIL)"
assert_eq "" "$(os_release_value SPACED)"
assert_eq "a b" "$(os_release_value ID_LIKE)"
assert_eq "" "$(os_release_value EMPTY default-not-used)"
assert_eq value "$(os_release_value TRAILING)"
assert_eq case "$(os_release_value lower)"
[[ ! -e pwned && ! -e $DS_TEST_ROOT/pwned ]] || ds_fail "os-release was executed"
assert_exit 1 os_release_value 'bad key'
assert_eq "[dotsteward] ERROR: os_release_value: invalid key: bad key" "$DS_STDERR"
export DOTSTEWARD_OS_RELEASE=$DS_TEST_ROOT/missing
assert_exit 1 os_release_value ID
assert_eq "[dotsteward] ERROR: cannot read os-release: $DS_TEST_ROOT/missing" "$DS_STDERR"
export DOTSTEWARD_OS_RELEASE=$DS_TEST_ROOT/os-release

# Login shell primitives over the harness user database and shells file.
ds_use_stubs sudo chsh getent
shells=$DOTSTEWARD_ETC_SHELLS
assert_eq "$shells" "$(platform_shells_file)"
assert_eq /etc/shells "$(unset DOTSTEWARD_ETC_SHELLS; platform_shells_file)"
assert_eq /bin/bash "$(platform_login_shell)"
ds_passwd_set other /usr/bin/fish
assert_eq /usr/bin/fish "$(platform_login_shell other)"
# Without DOTSTEWARD_PASSWD_CMD it asks getent; an unknown user is an error.
no_user_shell() {
  unset DOTSTEWARD_PASSWD_CMD
  platform_login_shell no-such-user
}
assert_exit 1 no_user_shell
assert_eq "[dotsteward] ERROR: cannot read the login shell of no-such-user" "$DS_STDERR"
: >"$DS_CALL_LOG"
assert_eq /usr/bin/fish "$(unset DOTSTEWARD_PASSWD_CMD; platform_login_shell other)"
assert_calls "getent passwd other"

platform_shells_contains /bin/bash || ds_fail "/bin/bash is listed"
! platform_shells_contains /bin/zsh || ds_fail "/bin/zsh is not listed"
! platform_shells_contains /bin || ds_fail "prefixes do not count"
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
[[ $(ds_calls_of sudo) == "sudo install -o root -g root -m 0644 $TMPDIR/dotsteward-shells."*" $shells" ]] ||
  ds_fail "unexpected install call: $(ds_calls_of sudo)"
[[ -z $(find "$TMPDIR" -name 'dotsteward-shells.*') ]] || ds_fail "temporary shells file left behind"
: >"$DS_CALL_LOG"
platform_set_login_shell "$HOME/.nix-profile/bin/zsh"
assert_calls "sudo chsh -s $HOME/.nix-profile/bin/zsh $USER" "chsh -s $HOME/.nix-profile/bin/zsh $USER"
assert_eq "$HOME/.nix-profile/bin/zsh" "$(platform_login_shell)"

# dpkg helpers over the fake database.
ds_use_stubs dpkg dpkg-query dpkg-deb apt-get
ds_dpkg_installed example-app 1.2.3-1 amd64 "Files=/usr/bin/example-app /usr/lib/udev/rules.d/51-example.rules /usr/share/doc/example-app"
mkdir -p "$DS_TEST_ROOT/fsroot/usr/lib/udev/rules.d"
dpkg_installed example-app || ds_fail "example-app is installed"
! dpkg_installed example-term || ds_fail "example-term is not installed"
assert_eq 1.2.3-1 "$(dpkg_version example-app)"
assert_eq "" "$(dpkg_version example-term)"
dpkg_version_at_least example-app 1.2.3 || ds_fail "1.2.3-1 >= 1.2.3"
dpkg_version_at_least example-app 1.2.3-1 || ds_fail "equal versions"
! dpkg_version_at_least example-app 1.10 || ds_fail "1.2.3-1 < 1.10"
! dpkg_version_at_least example-term 0.1 || ds_fail "a missing package is never recent enough"
ds_dpkg_config_files example-removed 2.0.0
! dpkg_installed example-removed || ds_fail "a config-files package is not installed"
! dpkg_version_at_least example-removed 1.0 || ds_fail "a config-files package is never recent enough"
# package_provides PACKAGE REGEX: a listed path matches and is a regular file.
! package_provides example-app '/udev/rules\.d/[0-9]+-example\.rules$' || ds_fail "the rules file does not exist yet"
ds_dpkg_installed example-app 1.2.3-1 amd64 "Files=$DS_TEST_ROOT/fsroot/usr/lib/udev/rules.d/51-example.rules $DS_TEST_ROOT/fsroot/usr/lib/udev/rules.d"
touch "$DS_TEST_ROOT/fsroot/usr/lib/udev/rules.d/51-example.rules"
package_provides example-app '/((usr/)?lib)/udev/rules\.d/[0-9]+-example\.rules$' || ds_fail "the rules file is provided"
! package_provides example-app '/rules\.d$' || ds_fail "a directory is not a provided file"
! package_provides example-term '.' || ds_fail "a missing package provides nothing"
# deb_field FILE FIELD
ds_fake_deb "$DS_TEST_ROOT/example-term.deb" example-term 0.9.0 arm64
assert_eq example-term "$(deb_field "$DS_TEST_ROOT/example-term.deb" Package)"
assert_eq arm64 "$(deb_field "$DS_TEST_ROOT/example-term.deb" Architecture)"
assert_exit 2 deb_field "$DS_TEST_ROOT/os-release" Package

# APT: update, then one install transaction; -y only with
# DOTSTEWARD_ASSUME_YES=1.
ds_apt_available example-term 0.9.0
: >"$DS_CALL_LOG"
apt_update
apt_install example-term "$DS_TEST_ROOT/example-term.deb"
assert_eq "sudo timeout 600 apt-get update
sudo apt-get install --no-install-recommends example-term $DS_TEST_ROOT/example-term.deb" "$(ds_calls_of sudo)"
assert_eq 0.9.0 "$(dpkg_version example-term)"
# A package mirror that stops answering cannot hang the transaction:
# apt-get update is bounded (600 s, DOTSTEWARD_APT_UPDATE_TIMEOUT) and tried
# once more after a timeout; two timeouts fail with timeout's status 124.
ds_stub_route apt-get 'update*' --sleep 10 --times 1
: >"$DS_CALL_LOG"
DOTSTEWARD_APT_UPDATE_TIMEOUT=1 assert_exit 0 apt_update
assert_eq "sudo timeout 1 apt-get update
sudo timeout 1 apt-get update" "$(ds_calls_of sudo)"
assert_eq "[dotsteward] WARNING: apt-get update did not finish within 1 s; trying once more" "$DS_STDERR"
ds_stub_route apt-get 'update*' --sleep 10 --times 2
: >"$DS_CALL_LOG"
DOTSTEWARD_APT_UPDATE_TIMEOUT=1 assert_exit 124 apt_update
assert_eq 2 "$(ds_call_count sudo)"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: apt-get update did not finish within 1 s twice; a package mirror does not answer"
ds_stub_clear_routes apt-get
# Another failure is not retried.
ds_stub_route apt-get 'update*' --exit 100 --times 1
: >"$DS_CALL_LOG"
assert_exit 100 apt_update
assert_eq 1 "$(ds_call_count sudo)"
ds_stub_clear_routes apt-get
: >"$DS_CALL_LOG"
DOTSTEWARD_ASSUME_YES=1 apt_install --reinstall example-term
assert_eq "sudo apt-get install -y --reinstall --no-install-recommends example-term" "$(ds_calls_of sudo)"
: >"$DS_CALL_LOG"
DOTSTEWARD_ASSUME_YES=0 apt_install example-term
assert_eq "sudo apt-get install --no-install-recommends example-term" "$(ds_calls_of sudo)"
assert_exit 1 apt_install
assert_eq "[dotsteward] ERROR: usage: apt_install [--reinstall] PACKAGE..." "$DS_STDERR"
# apt-get's own failure status propagates.
assert_exit 100 apt_install no-such-package
