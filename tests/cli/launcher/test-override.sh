# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The launcher's first step: DOTSTEWARD_CLI set means exec it, before any
# key, cache, state or Nix work, with the instance root exported.
# shellcheck source=tests/cli/launcher/helpers.sh
source "$DS_REPO_ROOT/tests/cli/launcher/helpers.sh"

launcher_use_stub_nix
inst=$DS_TEST_ROOT/instance
launcher_instance "$inst" </dev/null
fake=$DS_TEST_ROOT/dev-cli
launcher_fake_cli >"$fake"
chmod 0755 "$fake"

: >"$DS_CALL_LOG"
DOTSTEWARD_CLI=$fake assert_exit 0 "$inst/.dotsteward/cli.sh" gate --scope maintain "a b"
assert_eq "fake-cli instance=$inst" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_calls "$(_ds_call_line dotsteward gate --scope maintain "a b")"
[[ ! -e $DOTSTEWARD_STATE_ROOT/cli ]] || ds_fail "the override path wrote the launcher cache"

# A bare command name is looked up on PATH.
mkdir -p "$DS_TEST_ROOT/dev-bin"
ln -s "$fake" "$DS_TEST_ROOT/dev-bin/dotsteward-local"
: >"$DS_CALL_LOG"
PATH=$DS_TEST_ROOT/dev-bin:$PATH DOTSTEWARD_CLI=dotsteward-local assert_exit 0 \
  "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli instance=$inst" "$DS_STDOUT"
assert_calls "dotsteward version"
DOTSTEWARD_CLI=dotsteward-local assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: DOTSTEWARD_CLI is not an executable file: dotsteward-local" "$DS_STDERR"

# The override needs neither Nix nor flake.lock, and its status propagates.
rm -- "$inst/flake.lock"
no_nix=$(launcher_no_nix_path)
: >"$DS_CALL_LOG"
assert_exit 5 env PATH="$no_nix" __ETC_PROFILE_NIX_SOURCED=1 DOTSTEWARD_CLI="$fake" \
  LAUNCHER_FAKE_STATUS=5 "$inst/.dotsteward/cli.sh" version
assert_calls "dotsteward version"

# An empty value means unset: the launcher goes on to its own steps.
: >"$DS_CALL_LOG"
DOTSTEWARD_CLI="" assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_contains "$DS_STDERR" "flake.lock not found"
assert_calls

# A value that is not an executable file is refused with a clear message.
DOTSTEWARD_CLI=$DS_TEST_ROOT/missing assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: DOTSTEWARD_CLI is not an executable file: $DS_TEST_ROOT/missing" \
  "$DS_STDERR"
printf 'not executable\n' >"$DS_TEST_ROOT/plain"
DOTSTEWARD_CLI=$DS_TEST_ROOT/plain assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: DOTSTEWARD_CLI is not an executable file: $DS_TEST_ROOT/plain" \
  "$DS_STDERR"
mkdir -p "$DS_TEST_ROOT/a-dir"
DOTSTEWARD_CLI=$DS_TEST_ROOT/a-dir assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_contains "$DS_STDERR" "DOTSTEWARD_CLI is not an executable file"
