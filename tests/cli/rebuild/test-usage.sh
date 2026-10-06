# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Flags of rebuild, rollback and login-shell: help, usage errors and the
# guards that refuse before anything is written (unknown profile, unsafe
# identity). A refusal leaves the state root absent and calls nothing.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

# Help goes to standard output and exits 0 before any check.
for command in run_rebuild run_rollback run_login_shell; do
  assert_exit 0 "$command" --help
  assert_contains "$DS_STDOUT" "Usage: dotsteward"
done
assert_contains "$(run_rebuild -h)" "--framework-override REF"
assert_contains "$(run_rollback -h)" "--dry-run"
assert_contains "$(run_login_shell -h)" "set|migrate|check"

# The dispatcher lists the three commands with their summaries.
help=$("$rb_fw/cli/dotsteward" --help)
assert_contains "$help" "rebuild"
assert_contains "$help" "rollback"
assert_contains "$help" "login-shell"

refuses() {
  local message=$1
  shift
  assert_exit 1 "$@"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: $message"
}

refuses "rebuild: --profile is required" run_rebuild --switch
refuses "rebuild: --profile requires a value" run_rebuild --switch --profile
refuses "rebuild: --switch or --build-only is required" run_rebuild --profile workstation
refuses "rebuild: unknown option: --apply" run_rebuild --profile workstation --switch --apply
refuses "rebuild: --framework-override requires a value" run_rebuild --profile workstation --build-only \
  --framework-override
refuses "unsupported profile: other (profiles: workstation, fresh)" run_rebuild --profile other --switch

refuses "rollback: only --latest is supported" run_rollback --dry-run
refuses "rollback: --dry-run or --apply is required" run_rollback --latest
refuses "rollback: --dry-run and --apply cannot be combined" run_rollback --latest --dry-run --apply
refuses "rollback: --json requires --dry-run" run_rollback --latest --apply --json
refuses "rollback: unknown option: --profile" run_rollback --latest --dry-run --profile workstation

refuses "login-shell: set, migrate or check is required" run_login_shell --profile workstation
refuses "login-shell: unknown subcommand: switch" run_login_shell switch --profile workstation
refuses "login-shell: only one of set, migrate or check is allowed" run_login_shell set check --profile workstation
refuses "login-shell: --profile is required" run_login_shell check
refuses "unsupported profile: other (profiles: workstation, fresh)" run_login_shell check --profile other
refuses "login-shell: generation not found: $DS_TEST_ROOT/missing" run_login_shell check --profile workstation \
  --generation "$DS_TEST_ROOT/missing"

# The identity is interpolated into the generated host flake: an unsafe
# user name or home directory is refused before anything is written.
(
  export USER='bad"user'
  refuses "unsafe user name" run_rebuild --profile workstation --switch
)
mkdir -p "$DS_TEST_ROOT/home with space"
(
  export HOME="$DS_TEST_ROOT/home with space"
  refuses "unsafe HOME" run_rebuild --profile workstation --build-only
)

[[ ! -e $rb_state ]] || ds_fail "a refused command wrote the state root: $(tree_state "$rb_state")"
assert_calls
