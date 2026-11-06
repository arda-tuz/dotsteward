# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `dotsteward init --machine NAME` makes the machine that creates the instance its producer:
# [hosts] producer goes into workstation.toml, and the Nix side reads the file like any
# other. The name of the machine itself stays outside the directory of the instance, where
# `init` never writes: the next steps name the command, and a bootstrap asks anyway.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
mkdir -p "$DS_TEST_ROOT/instances"
dir=$DS_TEST_ROOT/instances/station

# A name a machine cannot have: nothing is written.
init_run 2 --dir "$dir" --remote "$init_remote" --machine Not_A_Name
assert_contains "$DS_STDERR" "--machine"
[[ ! -e $dir ]] || ds_fail "init wrote the directory"

init_run 0 --dir "$dir" --remote "$init_remote" --machine laptop-1 --json
assert_jq - '.next_steps | map(.command) | any(contains("host init --name laptop-1"))' <<<"$DS_STDOUT"
toml_json "$dir/workstation.toml" | assert_jq - '.hosts.producer == "laptop-1"'
[[ ! -e $dir/hosts && ! -e $DOTSTEWARD_STATE_ROOT/machine.json ]] || ds_fail "init named this machine"

# Without the option nothing changes.
other=$DS_TEST_ROOT/instances/other
init_run 0 --dir "$other" --remote "$init_remote" --json
assert_jq - '.next_steps | map(.command) | any(contains("host init")) | not' <<<"$DS_STDOUT"
toml_json "$other/workstation.toml" | assert_jq - 'has("hosts") | not'
