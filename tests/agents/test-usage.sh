# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Arguments of `dotsteward agents`: install or check, a
# required --profile of the instance, --generation PATH (a directory),
# --keep-going and --json. Usage errors exit 1 before anything is written;
# --help names every flag and exits 0. An empty instance (no components, no
# skills) passes in both modes.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

agents() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" agents "$@" </dev/null
}

assert_exit 0 agents --help
for flag in install check --profile --generation --keep-going --json; do
  assert_contains "$DS_STDOUT" "$flag"
done
assert_exit 0 agents check --help
assert_contains "$DS_STDOUT" "--keep-going"

before=$(home_state)
assert_exit 1 agents
assert_contains "$DS_STDERR" "install or check"
assert_exit 1 agents repair --profile workstation
assert_contains "$DS_STDERR" "unknown"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "--profile is required"
assert_exit 1 agents install --profile
assert_contains "$DS_STDERR" "--profile requires a value"
assert_exit 1 agents check --profile elsewhere
assert_contains "$DS_STDERR" "unsupported profile: elsewhere"
assert_exit 1 agents check --profile workstation --verbose
assert_contains "$DS_STDERR" "unknown option: --verbose"
assert_exit 1 agents check --profile workstation --generation "$DS_TEST_ROOT/missing"
assert_contains "$DS_STDERR" "generation not found: $DS_TEST_ROOT/missing"
assert_eq "$before" "$(home_state)" "usage errors write nothing"

# An unsafe identity is refused before any write.
assert_exit 1 env USER='Not Safe' "$agents_fw/cli/dotsteward" --instance "$agents_inst" agents install --profile workstation
assert_contains "$DS_STDERR" "unsafe user name"
assert_eq "$before" "$(home_state)"

# Nothing to do: both modes pass; install creates the layout, check then
# passes too.
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "[dotsteward] agent tools and skills installed (profile workstation)"
[[ -d $HOME/.agents/skills && ! -L $HOME/.agents/skills ]] || ds_fail "install creates the canonical skill directory"
[[ -d $HOME/.codex/skills && ! -L $HOME/.codex/skills ]] || ds_fail "install creates the legacy skill root"
assert_exit 0 run_agents check
assert_eq "$DS_STDOUT" "[dotsteward] agent tools and skills verified (profile workstation)"
assert_eq "$DS_STDERR" ""
assert_eq "$(temp_dirs)" "" "no temporary directory is left behind"
