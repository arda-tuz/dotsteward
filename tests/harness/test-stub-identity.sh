# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# User database and platform identity stubs: getent, chsh, id, dscl,
# sw_vers and xcode-select, all backed by the harness user database.

ds_use_stubs sudo getent chsh id dscl sw_vers xcode-select

me="dotsteward-test:x:1000:1000:dotsteward-test:$HOME:/bin/bash"

# --- getent ---------------------------------------------------------------
assert_eq "$me" "$(getent passwd dotsteward-test)"
assert_eq "$me" "$(getent passwd 1000)"
assert_eq "$me" "$(getent passwd)"
assert_exit 2 getent passwd nobody-here
assert_eq "" "$DS_STDOUT"
ds_group_add example-group dotsteward-test
assert_eq "example-group:x:1001:dotsteward-test" "$(getent group example-group)"
assert_exit 1 getent hosts example.invalid
assert_contains "$DS_STDERR" "Unknown database"

# --- chsh -------------------------------------------------------------------
shell_path=$HOME/.nix-profile/bin/zsh
assert_exit 1 chsh -s "$shell_path"
assert_contains "$DS_STDERR" "$shell_path is an invalid shell"
printf '%s\n' "$shell_path" >>"$DOTSTEWARD_ETC_SHELLS"
chsh -s "$shell_path"
assert_eq "$shell_path" "$(getent passwd dotsteward-test | cut -d: -f7)"
assert_eq "$shell_path" "$("$DOTSTEWARD_PASSWD_CMD" | cut -d: -f7)"
chsh --shell /bin/bash dotsteward-test
assert_eq /bin/bash "$(ds_passwd_field dotsteward-test 7)"
ds_passwd_set other-user /bin/sh
assert_exit 1 chsh -s /bin/bash other-user
assert_contains "$DS_STDERR" "may not change the shell for 'other-user'"
sudo chsh -s /bin/bash other-user
assert_eq /bin/bash "$(ds_passwd_field other-user 7)"
assert_exit 1 sudo chsh -s /bin/bash nobody-here
assert_contains "$DS_STDERR" "user 'nobody-here' does not exist"
assert_exit 1 chsh
assert_contains "$DS_STDERR" "Usage"

# --- id -----------------------------------------------------------------------
assert_eq 1000 "$(id -u)"
assert_eq 1000 "$(id -g)"
assert_eq dotsteward-test "$(id -un)"
assert_eq dotsteward-test "$(id -nu)"
assert_eq "dotsteward-test example-group" "$(id -Gn)"
assert_eq "1000 1001" "$(id -G)"
assert_eq "uid=1000(dotsteward-test) gid=1000(dotsteward-test) groups=1000(dotsteward-test),1001(example-group)" "$(id)"
assert_eq 1001 "$(id -u other-user)"
assert_exit 1 id -u nobody-here
assert_contains "$DS_STDERR" "no such user"
assert_eq "0 root" "$(sudo id -u) $(sudo id -un)"

# --- dscl ---------------------------------------------------------------------
assert_eq "UserShell: /bin/bash" "$(dscl . -read "/Users/dotsteward-test" UserShell)"
assert_eq "NFSHomeDirectory: $HOME" "$(dscl . -read "/Users/dotsteward-test" NFSHomeDirectory)"
assert_exit 56 dscl . -read /Users/example UserShell
assert_contains "$DS_STDERR" "eDSRecordNotFound"
assert_exit 1 dscl . -create /Users/dotsteward-test UserShell /bin/sh
assert_contains "$DS_STDERR" "eDSPermissionError"
sudo dscl . -create /Users/dotsteward-test UserShell /bin/sh
assert_eq /bin/sh "$(ds_passwd_field dotsteward-test 7)"
assert_eq "dotsteward-test
other-user" "$(dscl . -list /Users)"

# --- sw_vers ----------------------------------------------------------------
assert_eq 15.0 "$(sw_vers -productVersion)"
assert_eq macOS "$(sw_vers -productName)"
assert_eq 24A335 "$(sw_vers -buildVersion)"
ds_stub_set sw_vers product-version 14.6.1
assert_eq 14.6.1 "$(sw_vers -productVersion)"
assert_contains "$(sw_vers)" "ProductVersion:		14.6.1"
assert_exit 1 sw_vers -bogus

# --- xcode-select -------------------------------------------------------------
clt=$DS_SYSTEM_ROOT/Library/Developer/CommandLineTools
assert_eq "$clt" "$(xcode-select -p)"
[[ -d $clt ]] || ds_fail "command line tools directory missing"
assert_exit 1 xcode-select --install
assert_contains "$DS_STDERR" "already installed"
ds_stub_set xcode-select installed 0
assert_exit 2 xcode-select -p
assert_contains "$DS_STDERR" "unable to get active developer directory"
assert_exit 0 xcode-select --install
assert_contains "$DS_STDOUT" "install requested"
assert_eq "$clt" "$(xcode-select --print-path)"
# An install that never completes keeps the tools missing.
ds_stub_set xcode-select installed 0
ds_stub_set xcode-select install-completes 0
xcode-select --install >/dev/null
assert_exit 2 xcode-select -p
assert_contains "$(xcode-select --version)" "xcode-select version"
