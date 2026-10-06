# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rebuild refuses an instance Nix would not see as committed (SPEC 6.2, 6.3,
# I-2) before any write and before any Nix call: a modified tracked file,
# an untracked file (Nix does not see it), a missing flake.lock, a checkout
# that is not a git repository root and a path that cannot be written into
# the host flake. Nothing appears under the state root.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

refused_before_writes() {
  [[ ! -e $rb_state ]] || ds_fail "the refusal wrote the state root: $(tree_state "$rb_state")"
  assert_calls
}

# A modified tracked file.
printf '# local edit\n' >>"$rb_inst/flake.nix"
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance repository is not clean; review and commit the changes first: flake.nix"
refused_before_writes
git -C "$rb_inst" checkout -q -- flake.nix

# An untracked file, also with --build-only.
mkdir -p "$rb_inst/components/example-term"
printf '{ }\n' >"$rb_inst/components/example-term/default.nix"
assert_exit 1 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: Nix does not see untracked files; run 'git add -A' first: components/"
refused_before_writes
# Staged but not committed: still not clean.
git -C "$rb_inst" add -A
assert_exit 1 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDERR" "the instance repository is not clean; review and commit the changes first: components/example-term/default.nix"
refused_before_writes
git -C "$rb_inst" reset -q --hard

# Ignored files do not make the tree dirty.
printf 'cache/\n' >"$rb_inst/.gitignore"
instance_commit "ignore the cache"
mkdir -p "$rb_inst/cache"
printf 'x\n' >"$rb_inst/cache/entry"
assert_exit 0 run_rebuild --profile workstation --build-only
rm -rf -- "$rb_state"
: >"$DS_CALL_LOG"

# A missing flake.lock (committed deletion, so the tree is clean).
git -C "$rb_inst" rm -q flake.lock
instance_commit "no lock"
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: instance flake.lock not found: $rb_inst/flake.lock"
refused_before_writes
git -C "$rb_inst" revert --no-edit HEAD >/dev/null

# Not a git repository, and a subdirectory of one.
mv "$rb_inst/.git" "$DS_TEST_ROOT/saved-git"
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance is not the root of a git repository: $rb_inst"
refused_before_writes
mv "$DS_TEST_ROOT/saved-git" "$rb_inst/.git"
outer=$DS_TEST_ROOT/outer
mkdir -p "$outer"
cp -R "$rb_inst" "$outer/instance"
rm -rf -- "$outer/instance/.git"
git -C "$outer" init -q
git -C "$outer" add -A
git -C "$outer" commit -q -m outer
assert_exit 1 "$rb_fw/cli/dotsteward" --instance "$outer/instance" rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance is not the root of a git repository: $outer/instance"
refused_before_writes

# A checkout path that cannot be interpolated into the host flake.
odd=$DS_TEST_ROOT/odd#checkout
cp -R "$rb_inst" "$odd"
assert_exit 1 "$rb_fw/cli/dotsteward" --instance "$odd" rebuild --profile workstation --build-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unsafe instance path for the host flake: $odd"
refused_before_writes
