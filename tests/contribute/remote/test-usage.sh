# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# The remote steps' arguments (SPEC 9.4): help, unknown options and
# arguments, missing values and runs. No refusal runs an instance command,
# gh or Nix, or writes a state file.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

assert_untouched() {
  assert_calls
  [[ ! -e $ct_runs ]] || ds_fail "the contribute state directory was created"
}

reset_calls
assert_exit 0 run_contribute --help
for line in "  trial [--build-only]" "  publish [--pr-to-upstream]" "  release " \
  "  upgrade [--tag TAG] [--build-only]" "  abort " "  report [--json]" "5  back to check (publish)"; do
  assert_contains "$DS_STDOUT" "$line"
done
for step in trial publish release upgrade abort report; do
  assert_exit 0 run_contribute "$step" --help
  assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] contribute <step> [OPTION...]"
  assert_exit 1 run_contribute "$step" --bogus
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown option: --bogus"
  assert_exit 1 run_contribute "$step" extra
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: unexpected argument: extra"
  assert_exit 1 run_contribute "$step" --id
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: --id requires a value"
  assert_exit 1 run_contribute "$step"
  assert_contains "$DS_STDERR" "no contribute run; start one with: dotsteward contribute start --slug SLUG"
  assert_exit 1 run_contribute "$step" --id ../escape
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid run id: ../escape"
done
assert_exit 1 run_contribute upgrade --tag
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --tag requires a value"
assert_untouched
