# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G3, untracked files (SPEC 6.3, [gate] I7): Nix does not see untracked
# files, so the gate refuses them, listing every one, before any Nix or step
# command and without touching the record; ignored files are allowed.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

mkdir -p "$gate_inst/notes" "$gate_inst/new dir"
printf 'a\n' >"$gate_inst/notes/a.txt"
printf 'b\n' >"$gate_inst/new dir/b.txt"
assert_exit 1 run_gate --scope maintain
assert_eq "[dotsteward] ERROR: Nix does not see untracked files; run 'git add -A' first: new dir/b.txt notes/a.txt" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
assert_calls
[[ ! -e $gate_validation && ! -e $gate_log ]] || ds_fail "the refused gate wrote state"

# Staged files are tracked.
git -C "$gate_inst" add notes/a.txt
assert_exit 1 run_gate --scope maintain
assert_eq "[dotsteward] ERROR: Nix does not see untracked files; run 'git add -A' first: new dir/b.txt" "$DS_STDERR"
assert_calls

# Ignored files are not refused.
rm -rf -- "$gate_inst/new dir"
mkdir -p "$gate_inst/ignored"
printf 'cache\n' >"$gate_inst/ignored/cache.bin"
assert_exit 0 run_gate --scope maintain
assert_json "$gate_validation" '.result == "passed"'
