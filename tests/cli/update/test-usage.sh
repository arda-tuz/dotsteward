# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# P1 and P2, arguments and repository guards (SPEC 6.2, [gate] I2): --help
# prints the usage and exits 0 before any state write; a missing or unknown
# subcommand, option errors, an unsupported scope and a prepare without
# --official-sources-only are refused with exit 1; prepare and publish run
# only in a git clone on instance.branch whose origin URL is exactly
# instance.remote. No refusal writes state, touches the network or runs Nix.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

# Nothing ran and nothing was written.
assert_untouched() {
  assert_calls
  assert_no_network
  [[ ! -e $up_state ]] || ds_fail "the state directory was created: $(find "$up_state" -print)"
  assert_eq "" "$(temp_dirs)" "temporary directories left behind"
}

# --- help ---------------------------------------------------------------------

for help in -h --help; do
  assert_exit 0 run_update "$help"
  assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] update prepare --official-sources-only"
  assert_contains "$DS_STDOUT" "dotsteward [--instance DIR] update publish"
  assert_contains "$DS_STDOUT" "dotsteward [--instance DIR] update status"
  assert_contains "$DS_STDOUT" "--expected-base OID"
  assert_eq "" "$DS_STDERR"
  assert_untouched
  for subcommand in prepare publish status; do
    assert_exit 0 run_update "$subcommand" "$help"
    assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] update prepare"
    assert_eq "" "$DS_STDERR"
    assert_untouched
  done
done

# --help wins over options that would be refused later.
assert_exit 0 run_update prepare --scope weekly --help
assert_untouched
assert_exit 0 run_update publish --bogus --help
assert_untouched

# The dispatcher lists the command with its summary.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --help
assert_contains "$DS_STDOUT" "update"
assert_contains "$(grep -E '^  update ' <<<"$DS_STDOUT")" "maintenance transaction"

# --- subcommand ---------------------------------------------------------------

assert_exit 1 run_update
assert_eq "[dotsteward] ERROR: update requires a subcommand: prepare, publish or status" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
assert_untouched

for bad in validate bogus --scope ""; do
  assert_exit 1 run_update "$bad"
  assert_eq "[dotsteward] ERROR: unknown update subcommand: $bad (expected prepare, publish or status)" "$DS_STDERR"
  assert_untouched
done

# --- options ------------------------------------------------------------------

for subcommand in prepare publish status; do
  assert_exit 1 run_update "$subcommand" --bogus
  assert_eq "[dotsteward] ERROR: unknown argument: --bogus" "$DS_STDERR"
  assert_untouched
  assert_exit 1 run_update "$subcommand" extra
  assert_eq "[dotsteward] ERROR: unknown argument: extra" "$DS_STDERR"
  assert_untouched
done

# Options of one subcommand are unknown to the others.
assert_exit 1 run_update prepare --official-sources-only --expected-base "$(head_oid)"
assert_eq "[dotsteward] ERROR: unknown argument: --expected-base" "$DS_STDERR"
assert_untouched
assert_exit 1 run_update publish --official-sources-only
assert_eq "[dotsteward] ERROR: unknown argument: --official-sources-only" "$DS_STDERR"
assert_untouched
assert_exit 1 run_update publish --json
assert_eq "[dotsteward] ERROR: unknown argument: --json" "$DS_STDERR"
assert_untouched
assert_exit 1 run_update status --scope update
assert_eq "[dotsteward] ERROR: unknown argument: --scope" "$DS_STDERR"
assert_untouched
assert_exit 1 run_update publish --force
assert_eq "[dotsteward] ERROR: unknown argument: --force" "$DS_STDERR"
assert_untouched

check_value() {
  local subcommand=$1 option=$2
  shift 2
  assert_exit 1 run_update "$subcommand" "$@" "$option"
  assert_eq "[dotsteward] ERROR: $option requires a value" "$DS_STDERR"
  assert_untouched
  assert_exit 1 run_update "$subcommand" "$@" "$option" ""
  assert_eq "[dotsteward] ERROR: $option requires a value" "$DS_STDERR"
  assert_untouched
}
check_value prepare --scope --official-sources-only
check_value publish --scope
check_value publish --expected-base

assert_exit 1 run_update prepare --official-sources-only --scope weekly
assert_eq "[dotsteward] ERROR: unsupported scope: weekly (expected update or maintain)" "$DS_STDERR"
assert_untouched
assert_exit 1 run_update publish --scope weekly
assert_eq "[dotsteward] ERROR: unsupported scope: weekly (expected update or maintain)" "$DS_STDERR"
assert_untouched

# prepare requires the affirmation that only official sources are used.
assert_exit 1 run_update prepare
assert_eq "[dotsteward] ERROR: update prepare requires --official-sources-only" "$DS_STDERR"
assert_untouched
assert_exit 1 run_update prepare --scope maintain
assert_eq "[dotsteward] ERROR: update prepare requires --official-sources-only" "$DS_STDERR"
assert_untouched

# --- instance and repository guards -------------------------------------------

# No instance: neither --instance nor a workstation.toml above the working
# directory.
mkdir -p "$DS_TEST_ROOT/nowhere"
for subcommand in "prepare --official-sources-only" publish status; do
  # shellcheck disable=SC2016,SC2086 # expanded by the inner shell; the subcommand splits on purpose
  assert_exit 1 bash -c 'cd "$1" && shift && "$@" </dev/null' bash "$DS_TEST_ROOT/nowhere" \
    "$DS_REPO_ROOT/cli/dotsteward" update $subcommand
  assert_contains "$DS_STDERR" "[dotsteward] ERROR:"
  assert_contains "$DS_STDERR" "workstation.toml"
  assert_untouched
done

# guard EXPECTED_ERROR: prepare and publish are both refused with it.
guard() {
  assert_exit 1 run_update prepare --official-sources-only --scope maintain
  assert_eq "[dotsteward] ERROR: $1" "$DS_STDERR"
  assert_untouched
  assert_exit 1 run_update publish --scope maintain
  assert_eq "[dotsteward] ERROR: $1" "$DS_STDERR"
  assert_untouched
}

# Not a git clone: the instance inside a directory that is not its top level.
copy=$DS_TEST_ROOT/copy
cp -R "$up_inst" "$copy"
rm -rf -- "$copy/.git"
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$copy" update prepare --official-sources-only
assert_eq "[dotsteward] ERROR: maintenance runs only in a git clone: $copy" "$DS_STDERR"
assert_untouched
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$copy" update publish
assert_eq "[dotsteward] ERROR: maintenance runs only in a git clone: $copy" "$DS_STDERR"
assert_untouched

git -C "$up_inst" checkout -q -b feature
guard "maintenance branch must be main, not feature"
git -C "$up_inst" checkout -q main

git -C "$up_inst" checkout -q --detach
guard "maintenance branch must be main, not a detached HEAD"
git -C "$up_inst" checkout -q main

git -C "$up_inst" remote set-url origin "$UP_REMOTE/"
guard "unexpected origin URL: $UP_REMOTE/ (expected $UP_REMOTE)"
git -C "$up_inst" remote remove origin
guard "unexpected origin URL: (none) (expected $UP_REMOTE)"

# status reads the state only: it needs the instance, not a clean clone on
# the branch with the right origin.
assert_exit 0 run_update status
assert_untouched
