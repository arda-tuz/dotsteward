# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The codex plugins hook takes only the plugins of this machine: an entry with
# machines is for the machines it names, and hosts/<name>.toml declines a plugin
# for one machine. A plugin left out is neither installed nor missed.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs codex

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

inst=$(codex_instance scoped '["x86_64-linux"]' "method = \"external\"
options = { plugins = [
  { spec = \"alpha@other-market\" },
  { spec = \"beta@other-market\" },
] }")
codex_mirror "$inst"
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills" "$inst/hosts"

printf 'schema_version = 1\n' >"$inst/hosts/laptop.toml"
printf 'schema_version = 1\ndeclined = { plugins = ["beta@other-market"] }\n' >"$inst/hosts/desktop.toml"

# The machine that declined one.
export DOTSTEWARD_MACHINE=desktop
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex plugin alpha@other-market 1.0.0 verified"
assert_not_contains "$DS_STDOUT" "beta@other-market"
assert_call_count 0 codex 'plugin add beta@other-market'
assert_exit 0 agents check

# Everything is for this machine: the other one is missed until it is installed.
export DOTSTEWARD_MACHINE=laptop
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex plugin beta@other-market is not installed"
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex plugin beta@other-market 1.0.0 verified"
assert_exit 0 agents check

# A plugin entry that names machines is for those machines only.
sed -i 's/{ spec = "beta@other-market" }/{ spec = "beta@other-market", machines = ["desktop"] }/' "$inst/workstation.toml"
assert_exit 0 agents check
assert_not_contains "$DS_STDOUT" "beta@other-market"

# The same through the evaluation: the module takes the key, so the mirror holds the entry
# and the instance passes as it is.
inst=$(codex_instance scoped-nix '["x86_64-linux"]' "method = \"external\"
options = { plugins = [
  { spec = \"alpha@other-market\" },
  { spec = \"gamma@other-market\", machines = [\"desktop\"] },
] }")
codex_mirror "$inst"
mkdir -p "$inst/hosts"
printf 'schema_version = 1\n' >"$inst/hosts/laptop.toml"
printf 'schema_version = 1\n' >"$inst/hosts/desktop.toml"
export DOTSTEWARD_MACHINE=laptop
assert_exit 0 agents install
assert_not_contains "$DS_STDOUT" "gamma@other-market"
export DOTSTEWARD_MACHINE=desktop
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "gamma@other-market 1.0.0 verified"
