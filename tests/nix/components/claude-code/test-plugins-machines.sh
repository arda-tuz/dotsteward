# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The claude-code plugins hook takes only the plugins of this machine: an entry
# with machines is for the machines it names, and hosts/<name>.toml declines a
# plugin for one machine. A plugin left out is neither installed nor missed.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

nix_core_init

cc_hermetic_path
ds_use_stubs claude

agents() {
  cc_cli "$inst" agents "$1" --profile workstation
}

inst=$(cc_instance scoped "method = \"external\"
options = { plugins = [
  { spec = \"alpha@builtin-market\" },
  { spec = \"beta@builtin-market\" },
] }")
cc_mirror "$inst"
mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills" "$inst/hosts"
ds_stub_set claude builtin-marketplaces builtin-market

printf 'schema_version = 1\n' >"$inst/hosts/laptop.toml"
printf 'schema_version = 1\ndeclined = { plugins = ["beta@builtin-market"] }\n' >"$inst/hosts/desktop.toml"

# The machine that declined one.
export DOTSTEWARD_MACHINE=desktop
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "claude plugin alpha@builtin-market 1.0.0 verified"
assert_not_contains "$DS_STDOUT" "beta@builtin-market"
assert_call_count 0 claude 'plugin install beta@builtin-market *'
assert_exit 0 agents check

# Everything is for this machine: the other one is missed until it is installed.
export DOTSTEWARD_MACHINE=laptop
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin beta@builtin-market is not installed"
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "claude plugin beta@builtin-market 1.0.0 verified"
assert_exit 0 agents check

# A plugin entry that names machines is for those machines only.
sed -i 's/{ spec = "beta@builtin-market" }/{ spec = "beta@builtin-market", machines = ["desktop"] }/' "$inst/workstation.toml"
: >"$DS_CALL_LOG"
assert_exit 0 agents check
assert_not_contains "$DS_STDOUT" "beta@builtin-market"
export DOTSTEWARD_MACHINE=desktop
sed -i 's/declined = { plugins = \["beta@builtin-market"\] }//' "$inst/hosts/desktop.toml"
: >"$DS_CALL_LOG"
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "claude plugin beta@builtin-market 1.0.0 verified"

# The same through the evaluation: the module takes the key, so the mirror holds the entry
# and the instance passes as it is.
inst=$(cc_instance scoped-nix "method = \"external\"
options = { plugins = [
  { spec = \"alpha@builtin-market\" },
  { spec = \"gamma@builtin-market\", machines = [\"desktop\"] },
] }")
cc_mirror "$inst"
mkdir -p "$inst/hosts"
printf 'schema_version = 1\n' >"$inst/hosts/laptop.toml"
printf 'schema_version = 1\n' >"$inst/hosts/desktop.toml"
export DOTSTEWARD_MACHINE=laptop
assert_exit 0 agents install
assert_not_contains "$DS_STDOUT" "gamma@builtin-market"
export DOTSTEWARD_MACHINE=desktop
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "gamma@builtin-market 1.0.0 verified"
