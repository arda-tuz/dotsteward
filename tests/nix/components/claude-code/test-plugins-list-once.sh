# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The claude-code plugins hook reads each list of the claude CLI once per
# run: `claude plugin marketplace list --json` and `claude plugin list
# --json` answer every plugin entry, however many there are, and a list is
# read again only after a command that changes it (marketplace add for the
# marketplaces, plugin install or enable for the plugins). The checks stay
# the same: every entry is verified against the list as it is after the
# last change.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

nix_core_init

cc_hermetic_path
ds_use_stubs claude

repo=example-org/example-marketplace

agents() {
  cc_cli "$inst" agents "$1" --profile workstation
}

# lists: the number of marketplace and plugin list calls since the log was
# emptied.
lists() {
  printf '%s %s\n' "$(ds_call_count claude 'plugin marketplace list --json')" \
    "$(ds_call_count claude 'plugin list --json')"
}

inst=$(cc_instance list-once "method = \"external\"
options = { plugins = [
  { spec = \"alpha@example-market\", marketplace = \"$repo\" },
  { spec = \"beta@example-market\", marketplace = \"$repo\" },
  { spec = \"gamma@builtin-market\" },
] }")
cc_mirror "$inst"
mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills"
ds_stub_set claude marketplace-name example-market
ds_stub_set claude builtin-marketplaces builtin-market

# install from nothing: one marketplace add and three plugin installs, each
# followed by one new read of the list it changed.
: >"$DS_CALL_LOG"
assert_exit 0 agents install
for spec in alpha@example-market beta@example-market gamma@builtin-market; do
  assert_contains "$DS_STDOUT" "claude plugin $spec 1.0.0 verified"
done
assert_call_count 1 claude "plugin marketplace add $repo"
assert_call_count 3 claude 'plugin install *'
assert_eq "2 4" "$(lists)" "list calls of the first install (marketplaces, plugins)"

# Everything in place: one read of each list for all three entries, in
# both modes.
for mode in check install; do
  : >"$DS_CALL_LOG"
  assert_exit 0 agents "$mode"
  assert_contains "$DS_STDOUT" "claude plugin gamma@builtin-market 1.0.0 verified"
  assert_eq "1 1" "$(lists)" "list calls of agents $mode (marketplaces, plugins)"
  assert_call_count 0 claude 'plugin install *'
done

# A disabled plugin: install enables it and reads the plugin list once more
# to verify it.
jq -c '(.[] | select(.id == "beta@example-market") | .enabled) = false' \
  "$DS_STUB_STATE/claude/installed.json" >"$DS_TEST_ROOT/installed.json"
mv -- "$DS_TEST_ROOT/installed.json" "$DS_STUB_STATE/claude/installed.json"
: >"$DS_CALL_LOG"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude plugin beta@example-market is not installed and enabled at user scope"
: >"$DS_CALL_LOG"
assert_exit 0 agents install
assert_call_count 1 claude 'plugin enable beta@example-market --scope user'
assert_eq "1 2" "$(lists)" "list calls of an install that enables a plugin (marketplaces, plugins)"
