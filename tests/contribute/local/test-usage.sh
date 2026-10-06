# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The contribute dispatcher (SPEC 6.2, 9.4): help, the step list, unknown
# steps and options, and the remote steps when cli/lib/contribute-remote.sh
# is not installed. No refusal runs gh or Nix, touches the network or writes
# a state file.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

assert_untouched() {
  assert_calls
  assert_eq "" "$(network_calls)" "network connections"
  [[ ! -e $ct_runs ]] || ds_fail "the contribute state directory was created"
  [[ ! -e $ct_clone ]] || ds_fail "the clone was created"
}

# --- help ---------------------------------------------------------------------

for help in -h --help; do
  assert_exit 0 run_contribute "$help"
  assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] contribute <step> [OPTION...]"
  for step in mode setup start check trial publish release upgrade abort status; do
    assert_contains "$DS_STDOUT" "  $step"
  done
  assert_contains "$DS_STDOUT" "4  privacy hard stop"
done
assert_untouched

# A step's own --help prints the same usage.
assert_exit 0 run_contribute check --help
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] contribute <step> [OPTION...]"
assert_untouched

# The dispatcher lists the command with its summary.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --help
assert_contains "$DS_STDOUT" "contribute"
assert_contains "$DS_STDOUT" "Change the dotsteward framework itself"

# --- refusals -----------------------------------------------------------------

assert_exit 1 run_contribute
assert_contains "$DS_STDERR" "[dotsteward] ERROR: missing step"
assert_untouched

assert_exit 1 run_contribute bogus
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown contribute step: bogus"
assert_untouched

for step in mode setup start check status; do
  assert_exit 1 run_contribute "$step" --bogus
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown option: --bogus"
  assert_untouched
done

assert_exit 1 run_contribute mode extra
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unexpected argument: extra"
assert_untouched

assert_exit 1 run_contribute start
assert_contains "$DS_STDERR" "[dotsteward] ERROR: start requires --slug SLUG"
assert_untouched

assert_exit 1 run_contribute start --slug
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --slug requires a value"
assert_untouched

for slug in Bad_Slug -leading 'has space' 'a/b' "$(printf 'x%.0s' {1..61})"; do
  assert_exit 1 run_contribute start --slug "$slug"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid slug"
  assert_untouched
done

assert_exit 1 run_contribute check --expect-fail
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --expect-fail requires a value"
assert_untouched

# Without a run, the steps that need one say how to start it.
for step in check status; do
  assert_exit 1 run_contribute "$step"
  assert_contains "$DS_STDERR" "no contribute run; start one with: dotsteward contribute start --slug SLUG"
  assert_untouched
done
assert_exit 1 run_contribute status --id 20260101T000000Z-missing
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no contribute run with id 20260101T000000Z-missing"
assert_exit 1 run_contribute status --id ../escape
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid run id: ../escape"
assert_untouched

# --- remote steps without contribute-remote.sh ----------------------------------

# A framework copy without the remote library: its steps are refused by name.
framework=$DS_TEST_ROOT/framework
mkdir -p "$framework"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/privacy" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$framework/"
mkdir -p "$framework/modules/components"
for name in shell herdr claude-code codex opencode-pi vscode; do
  mkdir -p "$framework/modules/components/$name"
done
rm -f "$framework/cli/lib/contribute-remote.sh"
for step in trial publish release upgrade abort; do
  assert_exit 1 "$framework/cli/dotsteward" --instance "$ct_inst" contribute "$step"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: contribute $step is not available in this framework version"
  assert_untouched
done
