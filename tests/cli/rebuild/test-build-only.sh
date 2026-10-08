# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rebuild --build-only: the generated host
# flake keeps the host-override contract (input [compat] host_input of type
# path:, homeConfigurations.current = <input>.lib.mkHome (import
# ./profile.nix)), the files are private, inventory.json records the build,
# the build never updates a lock file, the state records name the built
# activation package and the profile, and nothing beyond the state root
# changes: no activation, no hooks, no settings, no agents, no login shell.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

add_hook pre_activate example-app record <<EOF
printf 'pre-activate\n' >>$(printf %q "$DS_TEST_ROOT/hook-ran")
EOF
revision=$(git -C "$rb_inst" rev-parse HEAD)
instance_lock=$(sha256sum "$rb_inst/flake.lock")
home_before=$(tree_state "$HOME")

assert_exit 0 run_rebuild --profile workstation --build-only
generation=$(<"$rb_current/last-built-activation")
assert_eq "$rb_store" "$(dirname "$generation")" "the record names a store path"
[[ -x $generation/activate ]] || ds_fail "the recorded generation has no activate script"
assert_eq "workstation" "$(<"$rb_current/profile")"
assert_contains "$DS_STDOUT" "[dotsteward] building the Home Manager activation package"
assert_contains "$DS_STDOUT" "[dotsteward] build finished; the user state was not changed"

# Host overrides: byte-exact files (an instance's host_input reproduces
# the same host flake), private modes.
assert_eq "{
  username = \"$USER\";
  homeDirectory = \"$HOME\";
  profile = \"workstation\";
}" "$(<"$rb_hosts/profile.nix")"
assert_eq "{
  inputs.dotfiles.url = \"path:$rb_inst\";

  outputs = { self, dotfiles }:
    let
      profile = import ./profile.nix;
    in
    {
      homeConfigurations.current = dotfiles.lib.mkHome profile;
    };
}" "$(<"$rb_hosts/flake.nix")"
for path in "$rb_state" "$rb_hosts" "$rb_current"; do
  assert_file_mode "$path" 700
done
for path in "$rb_hosts"/{flake.nix,profile.nix,flake.lock,inventory.json} \
  "$rb_current"/{last-built-activation,profile}; do
  assert_file_mode "$path" 600
done
assert_json "$rb_hosts/inventory.json" "
  .schema_version == \"1.0\" and .username == \"$USER\" and .home == \"$HOME\"
  and .profile == \"workstation\" and .canonical_repo == \"$rb_inst\"
  and .canonical_revision == \"$revision\" and .tracked_repo_mutation == false
  and .framework_override == null
  and (.generated_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\"))
  and (keys | length) == 9"

# Nix calls: the host lock first, then one build that never updates a lock.
assert_eq "nix --extra-experimental-features nix-command\\ flakes flake lock $rb_hosts
nix --extra-experimental-features nix-command\\ flakes build $rb_hosts#homeConfigurations.current.activationPackage --no-link --no-update-lock-file --print-out-paths" \
  "$(ds_calls_of nix)"
assert_eq 0 "$(ds_call_count activate)"
assert_eq 0 "$(ds_call_count local-maintained-files)"
assert_eq 0 "$(ds_call_count sudo)"
[[ ! -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "build-only ran a preActivate hook"
[[ ! -e $rb_current/previous-generation ]] || ds_fail "build-only captured the previous generation"
assert_eq "$instance_lock" "$(sha256sum "$rb_inst/flake.lock")"
assert_eq "$home_before" "$(tree_state "$HOME")" "build-only changed the home directory"
assert_eq "" "$(git -C "$rb_inst" status --porcelain)"

# A second profile: the records follow the last build.
assert_exit 0 run_rebuild --profile fresh --build-only
assert_eq "fresh" "$(<"$rb_current/profile")"
assert_contains "$(<"$rb_hosts/profile.nix")" 'profile = "fresh";'
assert_json "$rb_hosts/inventory.json" '.profile == "fresh"'

# The input name follows [compat] host_input; the default is "instance".
python3 - "$rb_inst/workstation.toml" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read().replace('\n[compat]\nhost_input = "dotfiles"\n', '\n')
open(path, "w").write(text)
EOF
instance_commit "default host input"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$(<"$rb_hosts/flake.nix")" "inputs.instance.url = \"path:$rb_inst\";"
assert_contains "$(<"$rb_hosts/flake.nix")" "outputs = { self, instance }:"
assert_contains "$(<"$rb_hosts/flake.nix")" "homeConfigurations.current = instance.lib.mkHome profile;"

# A failed build stops before the records change, with the build's status.
printf '%s\n' "$generation" >"$rb_current/last-built-activation"
printf '7\n' >"$DS_TEST_ROOT/build-exit"
assert_exit 7 run_rebuild --profile fresh --build-only
assert_eq "$generation" "$(<"$rb_current/last-built-activation")"
assert_eq "workstation" "$(<"$rb_current/profile")"
rm -f -- "$DS_TEST_ROOT/build-exit"

# An activation package without an executable activate script is refused.
: >"$DS_CALL_LOG"
ds_stub_override nix <<EOF
#!$BASH
mkdir -p $(printf %q "$rb_store")/00000000000000000000000000000000-broken
printf '%s\n' $(printf %q "$rb_store")/00000000000000000000000000000000-broken
EOF
assert_exit 1 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: activation script not found: $rb_store/00000000000000000000000000000000-broken/activate"
