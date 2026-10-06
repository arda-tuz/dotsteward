# shellcheck shell=bash
# `dotsteward pins check` on a green synthetic instance: success line with a
# stable check count, offline (no Nix call, read-only tree), instance
# discovery (--instance of the dispatcher and of the engine,
# DOTSTEWARD_INSTANCE, the working directory) and the command line surface.
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance
ds_use_stubs nix

assert_exit 0 pins check
count=$(check_count)
assert_eq "" "$DS_STDERR" "stderr of a green check"
((count > 50)) || ds_fail "suspiciously few checks: $count"
assert_calls

# The count is stable.
assert_exit 0 pins check
assert_eq "[pins] All pin consistency checks passed ($count checks)" "$DS_STDOUT"

# A read-only tree (the Nix store in the sandbox) is enough: check writes
# nothing, not even Python bytecode.
before=$(cd "$inst" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
chmod -R a-w "$inst"
ds_defer chmod -R u+w "$inst"
assert_exit 0 pins check
chmod -R u+w "$inst"
after=$(cd "$inst" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
assert_eq "$before" "$after" "check created or removed files"
assert_exit 0 git -C "$inst" status --porcelain
assert_eq "" "$DS_STDOUT" "check changed the work tree"

# Untracked files do not matter without --nix.
printf 'scratch\n' >"$inst/untracked.txt"
assert_exit 0 pins check
rm -f "$inst/untracked.txt"

# Every lock entry adds checks.
json_edit "$versions" 'data["nix_packages"]["example-extra"] = {"expected": "1.0", "resolved": "1.0"}'
assert_exit 0 pins check
bigger=$(check_count)
((bigger > count)) || ds_fail "an extra nix package added no check ($bigger <= $count)"
pins_fresh

# Discovery: the engine's own --instance, DOTSTEWARD_INSTANCE, and the
# nearest workstation.toml above the working directory.
assert_exit 0 dotsteward pins --instance "$inst" check
assert_eq "[pins] All pin consistency checks passed ($count checks)" "$DS_STDOUT"
assert_exit 0 env DOTSTEWARD_INSTANCE="$inst" "$DS_REPO_ROOT/cli/dotsteward" pins check
assert_eq "[pins] All pin consistency checks passed ($count checks)" "$DS_STDOUT"
# shellcheck disable=SC2016 # expanded by the inner shell
assert_exit 0 bash -c 'cd "$1/agent/skills" && "$2/cli/dotsteward" pins check' bash "$inst" "$DS_REPO_ROOT"
assert_eq "[pins] All pin consistency checks passed ($count checks)" "$DS_STDOUT"

mkdir -p "$DS_TEST_ROOT/elsewhere"
# shellcheck disable=SC2016 # expanded by the inner shell
assert_exit 2 bash -c 'cd "$1" && "$2/cli/dotsteward" pins check' bash "$DS_TEST_ROOT/elsewhere" "$DS_REPO_ROOT"
assert_contains "$DS_STDERR" "[pins] ERROR: no instance found"
assert_not_contains "$DS_STDERR" "Traceback"

# Command line surface.
assert_exit 0 dotsteward pins --help
for word in check sync latest --instance; do
  assert_contains "$DS_STDOUT" "$word"
done
assert_exit 0 pins check --help
assert_contains "$DS_STDOUT" "--nix"
assert_exit 0 pins sync --help
assert_contains "$DS_STDOUT" "--skill"
assert_exit 0 pins latest --help
for word in --out --all --jobs; do
  assert_contains "$DS_STDOUT" "$word"
done
assert_exit 2 pins
assert_exit 2 pins example-subcommand
assert_exit 2 pins check --example-flag

# The dispatcher lists both commands.
assert_exit 0 dotsteward --help
assert_contains "$DS_STDOUT" "pins"
assert_contains "$DS_STDOUT" "sync"
assert_calls
