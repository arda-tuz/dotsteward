# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rebuild --switch ordering (SPEC 6.2, I-6, I-7): host lock, build, records,
# preActivate hooks (scoped to the profile), previous-generation capture
# (once; ABSENT when no Home Manager profile exists), activate, settings
# apply with the generation's local-maintained-files, agents install (its
# hooks run), login shell migrate, final lock assertion. A failing step
# stops everything after it with its own status.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

recorder() {
  cat <<EOF
source $(printf %q "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call hook "$1" "profile=\$DOTSTEWARD_PROFILE" "mode=\$DOTSTEWARD_PROFILE_MODE" "component=\$DOTSTEWARD_COMPONENT"
EOF
}
recorder pre-activate | add_hook pre_activate example-app pre
recorder pre-activate-fresh | add_hook pre_activate example-term pre-fresh '["fresh"]'
recorder agents-install | add_hook agents_install example-app agents
manifest_edit '.components = [
  { name: "example-term", source: "instance", method: "external", profiles: null, platforms: ["linux"],
    options: {}, modes: { workstation: "adopt", fresh: "fresh" }, supported_methods: { linux: ["external"], darwin: [] },
    install: { command: null, versionArgv: null, minimum: null } },
  { name: "example-app", source: "instance", method: "external", profiles: null, platforms: ["linux"],
    options: {}, modes: { workstation: "adopt", fresh: "fresh" }, supported_methods: { linux: ["external"], darwin: [] },
    install: { command: null, versionArgv: null, minimum: null } }]'
set_config '[components.example-term]
enable = true

[components.example-app]
enable = true'
shells=$DOTSTEWARD_ETC_SHELLS
old_shell=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-zsh-5.9/bin/zsh
ds_passwd_set "$USER" "$old_shell"
instance_lock=$(sha256sum "$rb_inst/flake.lock")

assert_exit 0 run_rebuild --profile workstation --switch
generation=$(<"$rb_current/last-built-activation")
nix_prefix="nix --extra-experimental-features nix-command\\ flakes"
assert_calls \
  "$nix_prefix flake lock $rb_hosts" \
  "$nix_prefix build $rb_hosts#homeConfigurations.current.activationPackage --no-link --no-update-lock-file --print-out-paths" \
  "hook pre-activate profile=workstation mode=adopt component=example-app" \
  "activate" \
  "local-maintained-files --repo $rb_inst --state-dir $rb_state/local-maintained-files apply" \
  "hook agents-install profile=workstation mode=adopt component=example-app" \
  "sudo -n true" \
  "sudo tee -a $shells" \
  "sudo chsh -s $rb_zsh $USER" \
  "chsh -s $rb_zsh $USER"
assert_contains "$DS_STDOUT" "[dotsteward] activating the Home Manager generation"
assert_contains "$DS_STDOUT" "[dotsteward] rebuild finished: workstation"
assert_eq "ABSENT" "$(<"$rb_current/previous-generation")"
assert_file_mode "$rb_current/previous-generation" 600
assert_eq "$rb_zsh" "$(ds_passwd_field "$USER" 7)"
assert_eq "$instance_lock" "$(sha256sum "$rb_inst/flake.lock")"
[[ -d $HOME/.agents/skills ]] || ds_fail "agents install did not run its layout step"

# The record is written once: a Home Manager profile that exists now does
# not replace it. The fresh profile runs its own preActivate hooks.
mkdir -p "$HOME/.local/state/nix/profiles"
ln -s "$generation" "$HOME/.local/state/nix/profiles/home-manager"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile fresh --switch
assert_eq "ABSENT" "$(<"$rb_current/previous-generation")"
assert_eq "hook pre-activate-fresh profile=fresh mode=fresh component=example-term
hook pre-activate profile=fresh mode=fresh component=example-app" "$(ds_calls_of hook | grep pre-activate)"
assert_eq 0 "$(ds_call_count sudo)" "the stable login shell needs no change"

# --build-only together with --switch switches (the historical behaviour).
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only --switch
assert_eq 1 "$(ds_call_count activate)"

# Without a record, an existing Home Manager profile is recorded by its
# resolved generation.
rm -f -- "$rb_current/previous-generation"
assert_exit 0 run_rebuild --profile workstation --switch
assert_eq "$generation" "$(<"$rb_current/previous-generation")"
# A dangling profile link counts as no Home Manager.
rm -f -- "$rb_current/previous-generation" "$HOME/.local/state/nix/profiles/home-manager"
ln -s "$rb_store/00000000000000000000000000000000-gone" "$HOME/.local/state/nix/profiles/home-manager"
assert_exit 0 run_rebuild --profile workstation --switch
assert_eq "ABSENT" "$(<"$rb_current/previous-generation")"

# A failing preActivate hook stops before the capture and the activation.
rm -f -- "$rb_current/previous-generation"
add_hook pre_activate example-term fail <<'EOF'
echo "hook output" >&2
exit 3
EOF
: >"$DS_CALL_LOG"
assert_exit 3 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: component example-term hook fail failed (exit 3)"
assert_contains "$DS_STDERR" "hook output"
assert_eq 0 "$(ds_call_count activate)"
assert_eq 0 "$(ds_call_count local-maintained-files)"
[[ ! -e $rb_current/previous-generation ]] || ds_fail "the capture ran after a failed hook"
manifest_edit '.hooks.pre_activate |= map(select(.name != "fail"))'

# Hooks get the command's standard input (a hook may ask for a
# confirmation), never the list of the hooks still to run.
add_hook pre_activate example-term stdin <<'EOF'
if IFS= read -r line; then
  printf 'hook read stdin: %s\n' "$line" >&2
  exit 4
fi
EOF
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_eq 1 "$(ds_call_count hook 'pre-activate *')"
manifest_edit '.hooks.pre_activate |= map(select(.name != "stdin"))'

# A failed activation keeps the capture (I-7) and stops before settings.
ds_stub_route activate '*' --exit 5
: >"$DS_CALL_LOG"
assert_exit 5 run_rebuild --profile workstation --switch
assert_eq "ABSENT" "$(<"$rb_current/previous-generation")"
assert_eq 0 "$(ds_call_count local-maintained-files)"
ds_stub_clear_routes activate

# A settings structural error (exit 2) skips agents and the login shell.
ds_passwd_set "$USER" "$old_shell"
printf '2\n' >"$DS_TEST_ROOT/lmf-exit"
: >"$DS_CALL_LOG"
assert_exit 2 run_rebuild --profile workstation --switch
assert_eq 1 "$(ds_call_count local-maintained-files)"
assert_eq 0 "$(ds_call_count hook 'agents-install*')"
assert_eq 0 "$(ds_call_count sudo)"
rm -f -- "$DS_TEST_ROOT/lmf-exit"

# A generation without the local-maintained-files command (the alias is
# off) skips the settings apply with a warning and goes on.
: >"$DS_TEST_ROOT/no-lmf"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] WARNING: the generation has no local-maintained-files command; the settings apply is skipped"
assert_eq 0 "$(ds_call_count local-maintained-files)"
assert_eq 1 "$(ds_call_count hook 'agents-install*')"
rm -f -- "$DS_TEST_ROOT/no-lmf"
ds_passwd_set "$USER" "$old_shell"

# Without a managed login shell, the login shell is left alone.
manifest_edit '.login_shell = null'
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_eq 0 "$(ds_call_count sudo)"
assert_eq "$old_shell" "$(ds_passwd_field "$USER" 7)"

# The instance flake.lock is asserted unchanged at the end.
add_hook pre_activate example-app touch-lock <<EOF
printf '\n' >>$(printf %q "$rb_inst/flake.lock")
EOF
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: instance flake.lock changed unexpectedly: $rb_inst/flake.lock"
