# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G1, arguments and the repository guards (SPEC 6.2, [gate] I2, I6): --help
# prints the usage and exits 0 before any state write; option errors, an
# unsupported scope, a missing instance, a directory that is not a git clone,
# another branch and another origin URL are refused with exit 1 before the
# state directory is created and before any Nix or step command runs.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

# Nothing ran and nothing was written.
assert_untouched() {
  assert_calls
  [[ ! -e $gate_state ]] || ds_fail "the state directory was created: $(find "$gate_state" -print)"
  assert_eq "" "$(temp_dirs)" "temporary directories left behind"
}

assert_exit 0 run_gate --help
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] gate"
assert_contains "$DS_STDOUT" "--scope update|maintain"
assert_contains "$DS_STDOUT" "--framework-override REF"
assert_eq "" "$DS_STDERR"
assert_untouched

assert_exit 0 run_gate -h
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] gate"
assert_untouched

# --help wins over options that would be refused later.
assert_exit 0 run_gate --scope weekly --help
assert_untouched

assert_exit 1 run_gate --bogus
assert_eq "[dotsteward] ERROR: unknown argument: --bogus" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
assert_untouched

assert_exit 1 run_gate extra
assert_eq "[dotsteward] ERROR: unknown argument: extra" "$DS_STDERR"
assert_untouched

for option in --scope --expected-base --framework-override; do
  assert_exit 1 run_gate "$option"
  assert_eq "[dotsteward] ERROR: $option requires a value" "$DS_STDERR"
  assert_untouched
  assert_exit 1 run_gate "$option" ""
  assert_eq "[dotsteward] ERROR: $option requires a value" "$DS_STDERR"
  assert_untouched
done

assert_exit 1 run_gate --scope weekly
assert_eq "[dotsteward] ERROR: unsupported scope: weekly (expected update or maintain)" "$DS_STDERR"
assert_untouched

# No instance: neither --instance nor a workstation.toml above the working
# directory.
mkdir -p "$DS_TEST_ROOT/elsewhere"
# shellcheck disable=SC2016 # expanded by the inner shell
assert_exit 1 bash -c 'cd "$1" && "$2/cli/dotsteward" gate </dev/null' bash "$DS_TEST_ROOT/elsewhere" "$gate_fw"
assert_contains "$DS_STDERR" "[dotsteward] ERROR:"
assert_contains "$DS_STDERR" "workstation.toml"
assert_untouched

# Not a git clone: a copy of the instance without .git.
copy=$DS_TEST_ROOT/copy
cp -R "$gate_inst" "$copy"
rm -rf -- "$copy/.git"
assert_exit 1 "$gate_fw/cli/dotsteward" --instance "$copy" gate
assert_eq "[dotsteward] ERROR: maintenance runs only in a git clone: $copy" "$DS_STDERR"
assert_untouched

# Another branch.
git -C "$gate_inst" checkout -q -b feature
assert_exit 1 run_gate
assert_eq "[dotsteward] ERROR: maintenance branch must be main, not feature" "$DS_STDERR"
assert_untouched
git -C "$gate_inst" checkout -q main

# A detached HEAD has no branch.
git -C "$gate_inst" checkout -q --detach
assert_exit 1 run_gate
assert_eq "[dotsteward] ERROR: maintenance branch must be main, not a detached HEAD" "$DS_STDERR"
assert_untouched
git -C "$gate_inst" checkout -q main

# The configured branch is the one required.
set_toml instance branch '"trunk"'
commit_all "chore: use trunk"
assert_exit 1 run_gate
assert_eq "[dotsteward] ERROR: maintenance branch must be trunk, not main" "$DS_STDERR"
assert_untouched
git -C "$gate_inst" reset -q --hard HEAD~1

# Another origin URL, compared byte for byte.
git -C "$gate_inst" remote set-url origin "$GATE_REMOTE/"
assert_exit 1 run_gate
assert_eq "[dotsteward] ERROR: unexpected origin URL: $GATE_REMOTE/ (expected $GATE_REMOTE)" "$DS_STDERR"
assert_untouched

git -C "$gate_inst" remote remove origin
assert_exit 1 run_gate
assert_eq "[dotsteward] ERROR: unexpected origin URL: (none) (expected $GATE_REMOTE)" "$DS_STDERR"
assert_untouched
