# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and manifest values are single-quoted on purpose
# login-shell set|migrate|check: the login shell is the
# manifest's login_shell ($HOME expanded), from --generation, else the
# active generation, else the instance's mirror. set adds it to the shells
# file (recorded in <state>/current/etc-shells-added-path) and sets it;
# migrate only moves a versioned Nix zsh to it and, without sudo and
# without a terminal, warns instead; check changes nothing and fails when
# the shell is not executable, not listed or not the user's login shell. A
# null login_shell means the instance does not manage it.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

shells=$DOTSTEWARD_ETC_SHELLS
record=$rb_current/etc-shells-added-path
versioned=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-zsh-5.9/bin/zsh
older=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-zsh-5.8/bin/zsh

# check on a fresh machine: not listed, then not the login shell.
assert_exit 1 run_login_shell check --profile workstation
assert_contains "$DS_STDERR" "[dotsteward] ERROR: login shell is not listed in $shells: $rb_zsh"
printf '%s\n' "$rb_zsh" >>"$shells"
assert_exit 1 run_login_shell check --profile workstation
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the login shell of $USER is /bin/bash, not $rb_zsh; run 'dotsteward login-shell set --profile workstation' in a terminal"
chmod 0644 "$rb_zsh"
assert_exit 1 run_login_shell check --profile workstation
assert_contains "$DS_STDERR" "[dotsteward] ERROR: login shell is not executable: $rb_zsh"
chmod 0755 "$rb_zsh"
grep -Fxv -- "$rb_zsh" "$shells" >"$DS_TEST_ROOT/shells" || true
cat -- "$DS_TEST_ROOT/shells" >"$shells"
assert_calls
[[ ! -e $rb_state ]] || ds_fail "check wrote the state root: $(tree_state "$rb_state")"

# migrate leaves a shell that is not a versioned Nix zsh alone.
assert_exit 0 run_login_shell migrate --profile workstation
assert_calls
assert_eq "/bin/bash" "$(ds_passwd_field "$USER" 7)"

# set: listed (and recorded), then set.
assert_exit 0 run_login_shell set --profile workstation
assert_calls \
  "sudo tee -a $shells" \
  "sudo chsh -s $rb_zsh $USER" \
  "chsh -s $rb_zsh $USER"
assert_eq "$rb_zsh" "$(ds_passwd_field "$USER" 7)"
assert_contains "$(<"$shells")" "$rb_zsh"
assert_eq "$rb_zsh" "$(<"$record")"
assert_file_mode "$record" 600
assert_file_mode "$rb_current" 700
assert_exit 0 run_login_shell check --profile workstation
assert_contains "$DS_STDOUT" "[dotsteward] login shell ok: $rb_zsh"
# Nothing left to do.
: >"$DS_CALL_LOG"
assert_exit 0 run_login_shell set --profile workstation
assert_calls

# migrate from a versioned Nix zsh: the stable path is set and the
# versioned line this system recorded earlier is removed.
printf '%s\n%s\n' "$versioned" "$older" >>"$shells"
printf '%s\n' "$older" >"$record"
ds_passwd_set "$USER" "$versioned"
: >"$DS_CALL_LOG"
assert_exit 0 run_login_shell migrate --profile workstation
assert_eq "sudo -n true
sudo chsh -s $rb_zsh $USER" "$(ds_calls_of sudo | grep -v '^sudo install ')"
assert_eq 1 "$(ds_call_count sudo 'install -o root -g root -m 0644 *')"
assert_eq "$rb_zsh" "$(ds_passwd_field "$USER" 7)"
assert_not_contains "$(<"$shells")" "$older"
assert_contains "$(<"$shells")" "$versioned"
[[ ! -e $record ]] || ds_fail "the record of the removed line was kept"

# migrate without sudo rights and without a terminal only warns.
ds_passwd_set "$USER" "$versioned"
ds_stub_route sudo '-n true' --exit 1
: >"$DS_CALL_LOG"
assert_exit 0 run_login_shell migrate --profile fresh
assert_contains "$DS_STDERR" "[dotsteward] WARNING: the login shell is on a versioned Nix path ($versioned); garbage collection can remove it. Run './rebuild.sh --profile fresh --switch' in a terminal to move it to the stable path ($rb_zsh)."
assert_calls "sudo -n true"
assert_eq "$versioned" "$(ds_passwd_field "$USER" 7)"
ds_stub_clear_routes sudo

# --generation reads that generation's manifest; ${HOME} is expanded too.
manifest_edit '.login_shell = "${HOME}/.nix-profile/bin/zsh"'
generation=$(make_generation home-manager-braced)
ds_passwd_set "$USER" "$rb_zsh"
assert_exit 0 run_login_shell check --profile workstation --generation "$generation"
manifest_edit '.login_shell = null'
unmanaged=$(make_generation home-manager-unmanaged)
ds_passwd_set "$USER" /bin/bash
assert_exit 1 run_login_shell check --profile workstation --generation "$generation"
# The active generation comes before the mirror.
use_generation "$generation"
assert_exit 1 run_login_shell check --profile workstation
rm -f -- "$rb_hm_profile"

# A null login_shell: nothing to set, migrate or check.
: >"$DS_CALL_LOG"
for mode in set migrate check; do
  assert_exit 0 run_login_shell "$mode" --profile workstation
  assert_contains "$DS_STDOUT" "[dotsteward] the instance does not manage the login shell"
  assert_exit 0 run_login_shell "$mode" --profile workstation --generation "$unmanaged"
done
assert_calls
assert_eq "/bin/bash" "$(ds_passwd_field "$USER" 7)"

# A login shell that is not an absolute path is refused.
manifest_edit '.login_shell = "bin/zsh"'
assert_exit 1 run_login_shell set --profile workstation
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid login shell in the manifest (expected an absolute path): bin/zsh"
assert_calls
