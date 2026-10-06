# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The template wrappers (SPEC 6.4): rebuild.sh and rollback.sh pass every
# argument to `dotsteward rebuild` and `dotsteward rollback`; update.sh maps
# its subcommands prepare, validate, publish and status to `dotsteward
# update prepare`, `dotsteward gate`, `dotsteward update publish` and
# `dotsteward update status`, and prints its usage for -h before anything
# runs. All of them exec the instance launcher .dotsteward/cli.sh, from any
# working directory and through symbolic links; the CLI is replaced by a
# recording stub through the launcher's DOTSTEWARD_CLI override.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the template tests need shellcheck on PATH"

for wrapper in rebuild.sh rollback.sh update.sh; do
  [[ -f $tpl/$wrapper ]] || ds_fail "template/$wrapper is missing"
  bash -n "$tpl/$wrapper" || ds_fail "template/$wrapper is not valid bash"
  grep -qx 'set -Eeuo pipefail' "$tpl/$wrapper" || ds_fail "template/$wrapper lacks set -Eeuo pipefail"
  # The wrappers translate arguments only; they never read legacy
  # environment names (the framework does, with [compat] legacy_env).
  if grep -q 'DOTFILES_' "$tpl/$wrapper"; then
    ds_fail "template/$wrapper maps a legacy environment variable"
  fi
done
(cd "$tpl" && shellcheck rebuild.sh rollback.sh update.sh) || ds_fail "shellcheck reported findings in the wrappers"

inst=$DS_TEST_ROOT/instance
mkdir -p "$inst"
cp -R "$tpl/." "$inst/"
chmod -R u+w "$inst"
inst=$(cd "$inst" && pwd -P)

# The stub CLI records the instance the launcher exported and its
# arguments, one %q-quoted word per line, and exits with STUB_STATUS.
record=$DS_TEST_ROOT/record
stub=$DS_TEST_ROOT/stub-dotsteward
cat >"$stub" <<EOF
#!$BASH
{
  printf 'instance=%s\n' "\$DOTSTEWARD_INSTANCE"
  for arg in "\$@"; do printf '%q\n' "\$arg"; done
} >"$record"
exit "\${STUB_STATUS:-0}"
EOF
chmod +x "$stub"
export DOTSTEWARD_CLI=$stub

# calls_as EXPECTED_WORD... : the last stub call ran with these arguments
# for this instance; the record is consumed.
calls_as() {
  [[ -f $record ]] || ds_fail "the CLI was not called"
  local expected
  expected=$(printf 'instance=%s\n' "$inst"; printf '%q\n' "$@")
  assert_eq "$expected" "$(<"$record")" "CLI call"
  rm -f "$record"
}

not_called() {
  [[ ! -e $record ]] || ds_fail "the CLI was called: $(<"$record")"
}

# --- rebuild.sh and rollback.sh pass through ----------------------------------

cd "$inst"
assert_exit 0 ./rebuild.sh --profile workstation --switch
calls_as rebuild --profile workstation --switch
assert_exit 0 ./rebuild.sh
calls_as rebuild
assert_exit 0 ./rebuild.sh --help
calls_as rebuild --help
assert_exit 0 ./rollback.sh --latest --dry-run --json
calls_as rollback --latest --dry-run --json
# Words with spaces and glob characters arrive unchanged.
assert_exit 0 ./rollback.sh 'two words' '*' ''
calls_as rollback 'two words' '*' ''

# --- update.sh maps its subcommands --------------------------------------------

assert_exit 0 ./update.sh prepare --official-sources-only --scope maintain
calls_as update prepare --official-sources-only --scope maintain
assert_exit 0 ./update.sh validate --scope maintain --force --expected-base 0123abc
calls_as gate --scope maintain --force --expected-base 0123abc
assert_exit 0 ./update.sh publish --scope update --expected-base 0123abc
calls_as update publish --scope update --expected-base 0123abc
assert_exit 0 ./update.sh status --json
calls_as update status --json
assert_exit 0 ./update.sh validate
calls_as gate

# The CLI's exit status is the wrapper's.
STUB_STATUS=7 assert_exit 7 ./update.sh validate --force
calls_as gate --force
STUB_STATUS=3 assert_exit 3 ./rebuild.sh --profile fresh --build-only
calls_as rebuild --profile fresh --build-only

# Usage: -h, --help and help print it and exit 0 before anything runs; no
# subcommand and an unknown one are refused with exit 1.
for help in -h --help help; do
  assert_exit 0 ./update.sh "$help"
  assert_contains "$DS_STDOUT" "Usage: ./update.sh prepare|validate|publish|status [ARG...]"
  for subcommand in prepare validate publish status; do
    assert_contains "$DS_STDOUT" "  $subcommand "
  done
  assert_eq "" "$DS_STDERR" "update.sh $help writes nothing to stderr"
  not_called
done
assert_exit 1 ./update.sh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: update.sh needs a subcommand"
assert_contains "$DS_STDERR" "Usage: ./update.sh"
not_called
assert_exit 1 ./update.sh --prepare --official-sources-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: update.sh: unknown subcommand --prepare (expected prepare, validate, publish or status)"
not_called
assert_exit 1 ./update.sh rebuild
assert_contains "$DS_STDERR" "unknown subcommand rebuild"
not_called
# Nothing was written: no state, no file in the instance.
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print -quit)" "state written by the wrappers"

# --- any working directory, symbolic links ---------------------------------------

cd "$DS_TEST_ROOT"
assert_exit 0 "$inst/update.sh" status
calls_as update status
cd /
assert_exit 0 "$inst/rollback.sh" --latest --apply
calls_as rollback --latest --apply

mkdir -p "$DS_TEST_ROOT/bin" "$DS_TEST_ROOT/links"
ln -s "$inst/rebuild.sh" "$DS_TEST_ROOT/bin/ws-rebuild"
# A relative link to a relative link.
ln -s ../instance/update.sh "$DS_TEST_ROOT/links/update.sh"
ln -s ../links/update.sh "$DS_TEST_ROOT/bin/ws-update"
assert_exit 0 "$DS_TEST_ROOT/bin/ws-rebuild" --profile workstation --build-only
calls_as rebuild --profile workstation --build-only
assert_exit 0 "$DS_TEST_ROOT/bin/ws-update" publish
calls_as update publish
