# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# ensure_stable_login_shell set|migrate [PROFILE] through the platform layer
# (stubs: sudo, chsh, getent; the harness shells file and user database):
# the stable profile path, the record of the shells line this system added,
# idempotence, the migrate no-ops, the no-sudo warning and the cleanup of a
# recorded versioned line only.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

ds_use_stubs sudo chsh getent
shells=$DOTSTEWARD_ETC_SHELLS
record=$DOTSTEWARD_STATE_ROOT/current/etc-shells-added-path
zsh=$HOME/.nix-profile/bin/zsh
assert_eq "$zsh" "$(stable_zsh_path)"

# The stable path must be executable first.
assert_exit 1 ensure_stable_login_shell set
assert_eq "[dotsteward] ERROR: Nix zsh path is not executable: $zsh" "$DS_STDERR"
assert_calls
mkdir -p "$HOME/.nix-profile/bin"
printf '#!/bin/sh\nexit 0\n' >"$zsh"
chmod 0755 "$zsh"

# set on a fresh machine: the line is added and recorded, the shell changed.
assert_exit 0 ensure_stable_login_shell set
assert_calls "sudo tee -a $shells" "sudo chsh -s $zsh $USER" "chsh -s $zsh $USER"
assert_eq "$zsh" "$(tail -n 1 "$shells")"
assert_eq "$zsh" "$(<"$record")"
assert_file_mode "$record" 600
assert_file_mode "$(dirname "$record")" 700
assert_eq "$zsh" "$(ds_passwd_field "$USER" 7)"
# A second run changes nothing and calls nothing.
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell set
assert_calls
assert_eq 1 "$(grep -cFx "$zsh" "$shells")"

# migrate is a no-op unless the shell is a versioned Nix zsh.
assert_exit 0 ensure_stable_login_shell migrate main
assert_calls
ds_passwd_set "$USER" /bin/bash
assert_exit 0 ensure_stable_login_shell migrate main
assert_calls

# migrate from a versioned path that this system recorded: the stable path
# is set and the old recorded line removed.
old=/nix/store/aaaa-zsh-5.9/bin/zsh
printf '# /etc/shells: valid login shells\n/bin/sh\n/bin/bash\n%s\n' "$old" >"$shells"
printf '%s\n' "$old" >"$record"
ds_passwd_set "$USER" "$old"
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell migrate main
assert_eq "sudo -n true
sudo tee -a $shells
sudo chsh -s $zsh $USER" "$(ds_calls_of sudo | grep -v '^sudo install ')"
assert_eq 1 "$(ds_call_count sudo 'install -o root -g root -m 0644 *')"
assert_eq "# /etc/shells: valid login shells
/bin/sh
/bin/bash
$zsh" "$(<"$shells")"
assert_eq "$zsh" "$(<"$record")" "the record now names the line this run added"
assert_eq "$zsh" "$(ds_passwd_field "$USER" 7)"

# A versioned line this system did not record is never removed; the stable
# line already present is not added twice.
other=/nix/store/bbbb-zsh-5.9/bin/zsh
printf '%s\n' "$other" >>"$shells"
ds_passwd_set "$USER" "$other"
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell migrate main
assert_eq "sudo -n true
sudo chsh -s $zsh $USER" "$(ds_calls_of sudo)"
grep -Fxq "$other" "$shells" || ds_fail "an unrecorded line was removed"
assert_eq "$zsh" "$(<"$record")"

# A recorded line that is no longer listed needs no cleanup; the record is
# removed only when it still names the removed line.
printf '%s\n' "$old" >"$record"
ds_passwd_set "$USER" "$other"
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell migrate main
assert_eq 0 "$(ds_call_count sudo 'install *')"
assert_eq "$old" "$(<"$record")"
printf '%s\n' "$old" >>"$shells"
grep -v -Fx "$zsh" "$shells" >"$shells.new"
mv "$shells.new" "$shells"
ds_passwd_set "$USER" "$other"
assert_exit 0 ensure_stable_login_shell set
grep -Fxq "$zsh" "$shells" || ds_fail "the stable line was not added"
! grep -Fxq "$old" "$shells" || ds_fail "the recorded old line was not removed"
assert_eq "$zsh" "$(<"$record")"
# The record goes when the removed line is the one it names and this run
# did not add a line.
printf '%s\n' "$old" >>"$shells"
printf '%s\n' "$old" >"$record"
ds_passwd_set "$USER" "$zsh"
assert_exit 0 ensure_stable_login_shell set
[[ ! -e $record ]] || ds_fail "the record of the removed line is kept"
! grep -Fxq "$old" "$shells" || ds_fail "the recorded old line was not removed"

# migrate without sudo and without a terminal: one warning, no change.
ds_passwd_set "$USER" "$old"
ds_stub_route sudo '-n true' --exit 1
: >"$DS_CALL_LOG"
assert_exit 0 ensure_stable_login_shell migrate main
assert_eq "[dotsteward] WARNING: the login shell is on a versioned Nix path ($old); garbage collection can remove it. Run './rebuild.sh --profile main --switch' in a terminal to move it to the stable path ($zsh)." \
  "$DS_STDERR"
assert_calls "sudo -n true"
assert_eq "$old" "$(ds_passwd_field "$USER" 7)"
assert_exit 0 ensure_stable_login_shell migrate
assert_contains "$DS_STDERR" "'./rebuild.sh --profile <profile> --switch'"

# Usage.
assert_exit 1 ensure_stable_login_shell switch
assert_eq "[dotsteward] ERROR: usage: ensure_stable_login_shell set|migrate [PROFILE]" "$DS_STDERR"
