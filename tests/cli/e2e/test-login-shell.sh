# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # literal $HOME in the manifest on purpose
# Login shell through the platform layer (the shells
# file DOTSTEWARD_ETC_SHELLS and the user database DOTSTEWARD_PASSWD_CMD):
# the manifest's login_shell, with $HOME expanded, is executable, listed in
# the shells file and the user's login shell. A null login_shell is not
# checked.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

assert_exit 0 run_e2e --list
assert_not_contains "$DS_STDOUT" "core:login-shell"

manifest_edit '.login_shell = "$HOME/.nix-profile/bin/zsh"'
publish_instance
zsh_path=$HOME/.nix-profile/bin/zsh

assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg path "$zsh_path" '[["core:login-shell", "login-shell-not-executable", $path]]')" "$(findings)"
assert_contains "$DS_STDOUT" "login shell is not executable: $zsh_path"

mkdir -p "$(dirname "$zsh_path")"
printf '#!/bin/sh\nexit 0\n' >"$zsh_path"
chmod 0755 "$zsh_path"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg path "$zsh_path" '[["core:login-shell", "login-shell-not-listed", $path]]')" "$(findings)"
assert_contains "$DS_STDOUT" "login shell is not listed in $DOTSTEWARD_ETC_SHELLS: $zsh_path"

printf '%s\n' "$zsh_path" >>"$DOTSTEWARD_ETC_SHELLS"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg path "$zsh_path" '[["core:login-shell", "login-shell-mismatch", $path]]')" "$(findings)"
assert_contains "$DS_STDOUT" "the login shell of dotsteward-test is /bin/bash, not $zsh_path; run 'dotsteward rebuild --profile workstation --switch' in a terminal"

ds_passwd_set dotsteward-test "$zsh_path"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile workstation)"

# A versioned store path is not the stable path.
ds_passwd_set dotsteward-test /nix/store/00000000000000000000000000000000-zsh-5.9/bin/zsh
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "the login shell of dotsteward-test is /nix/store/00000000000000000000000000000000-zsh-5.9/bin/zsh, not $zsh_path"
assert_eq "" "$(temp_dirs)"
