# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The codex plugins hook reads each list of the codex CLI once per run:
# `codex plugin marketplace list --json` and `codex plugin list --json`
# answer every plugin entry, however many there are, and a list is read
# again only after a command that changes it (marketplace add for the
# marketplaces, plugin add for the plugins). The checks stay the same:
# every entry is verified against the list as it is after the last change.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs codex

repo=example-org/example-marketplace

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

# lists: the number of marketplace and plugin list calls since the log was
# emptied.
lists() {
  printf '%s %s\n' "$(ds_call_count codex 'plugin marketplace list --json')" \
    "$(ds_call_count codex 'plugin list --json')"
}

inst=$(codex_instance list-once '["x86_64-linux"]' "method = \"external\"
options = { plugins = [
  { spec = \"alpha@example-market\", marketplace = \"$repo\" },
  { spec = \"beta@example-market\", marketplace = \"$repo\" },
  { spec = \"gamma@other-market\" },
] }")
codex_mirror "$inst"
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
ds_stub_set codex marketplace-name example-market

# install from nothing: one marketplace add and three plugin adds, each
# followed by one new read of the list it changed.
: >"$DS_CALL_LOG"
assert_exit 0 agents install
for spec in alpha@example-market beta@example-market gamma@other-market; do
  assert_contains "$DS_STDOUT" "codex plugin $spec 1.0.0 verified"
done
assert_call_count 1 codex "plugin marketplace add $repo"
assert_call_count 3 codex 'plugin add *'
assert_eq "2 4" "$(lists)" "list calls of the first install (marketplaces, plugins)"

# Everything in place: one read of each list for all three entries, in
# both modes.
for mode in check install; do
  : >"$DS_CALL_LOG"
  assert_exit 0 agents "$mode"
  assert_contains "$DS_STDOUT" "codex plugin gamma@other-market 1.0.0 verified"
  assert_eq "1 1" "$(lists)" "list calls of agents $mode (marketplaces, plugins)"
  assert_call_count 0 codex 'plugin add *'
done
