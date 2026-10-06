# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# ensure_stable_login_shell set|migrate on darwin (stubs: sudo, dscl; the
# harness shells file and user database read through dscl, as on a Mac
# without DOTSTEWARD_PASSWD_CMD): the stable profile path is added to the
# shells file and recorded, the login shell is set with dscl, a second run
# changes nothing, and a recorded versioned line is removed again.
# shellcheck source=tests/cli/darwin/helpers.sh
source "$DS_REPO_ROOT/tests/cli/darwin/helpers.sh"
# shellcheck source=cli/lib/lib.sh
source "$darwin_lib_dir/lib.sh"

ds_use_stubs sudo dscl
unset DOTSTEWARD_PASSWD_CMD
ds_passwd_set "$USER" /bin/zsh
shells=$DOTSTEWARD_ETC_SHELLS
record=$DOTSTEWARD_STATE_ROOT/current/etc-shells-added-path
zsh=$HOME/.nix-profile/bin/zsh
mkdir -p "$HOME/.nix-profile/bin"
printf '#!/bin/sh\nexit 0\n' >"$zsh"
chmod 0755 "$zsh"

assert_exit 0 ensure_stable_login_shell set
assert_calls "dscl . -read /Users/$USER UserShell" \
  "sudo tee -a $shells" \
  "sudo dscl . -create /Users/$USER UserShell $zsh" \
  "dscl . -create /Users/$USER UserShell $zsh"
assert_eq "$zsh" "$(tail -n 1 "$shells")"
assert_eq "$zsh" "$(<"$record")"
assert_file_mode "$record" 600
assert_eq "$zsh" "$(ds_passwd_field "$USER" 7)"

# A second run only reads.
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell set
assert_calls "dscl . -read /Users/$USER UserShell"
assert_eq 1 "$(grep -cFx "$zsh" "$shells")"

# migrate from a versioned path this system recorded: the stable path is
# set and the recorded line removed (root-owned 0644, group wheel).
old=/nix/store/aaaa-zsh-5.9/bin/zsh
printf '# /etc/shells: valid login shells\n/bin/sh\n/bin/bash\n/bin/zsh\n%s\n' "$old" >"$shells"
printf '%s\n' "$old" >"$record"
ds_passwd_set "$USER" "$old"
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell migrate main
assert_eq "sudo -n true
sudo tee -a $shells
sudo dscl . -create /Users/$USER UserShell $zsh" "$(ds_calls_of sudo | grep -v '^sudo install ')"
assert_eq 1 "$(ds_call_count sudo 'install -o root -g wheel -m 0644 *')"
assert_eq "# /etc/shells: valid login shells
/bin/sh
/bin/bash
/bin/zsh
$zsh" "$(<"$shells")"
assert_eq "$zsh" "$(<"$record")"
assert_eq "$zsh" "$(ds_passwd_field "$USER" 7)"
