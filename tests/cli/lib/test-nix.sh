# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# source_nix_daemon (the user's Nix profile first on PATH) and nix_cmd (nix
# with the flakes features).
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

ds_use_stubs nix
original_path=$PATH

# Without ~/.nix-profile/bin, PATH is unchanged.
source_nix_daemon
assert_eq "$original_path" "$PATH"
# With it, it comes first, every time (as today).
mkdir -p "$HOME/.nix-profile/bin"
source_nix_daemon
assert_eq "$HOME/.nix-profile/bin:$original_path" "$PATH"
PATH=$original_path

# nix_cmd passes every argument after the features.
nix_cmd build --no-link '.#checks.x86_64-linux.cli-lib' 'arg with space'
assert_calls "nix --extra-experimental-features nix-command\\ flakes build --no-link .#checks.x86_64-linux.cli-lib arg\\ with\\ space"
assert_eq "$HOME/.nix-profile/bin:$original_path" "$PATH" "nix_cmd sources the profile"
PATH=$original_path
# The child's status propagates.
ds_stub_route nix 'eval *' --exit 3 --stderr 'error: broken'
assert_exit 3 nix_cmd eval .#x
assert_eq "error: broken" "$DS_STDERR"
