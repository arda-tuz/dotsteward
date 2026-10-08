# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Dirty trees and untracked files of the launcher, with the
# real Nix against an isolated store: the launcher works on a dirty tree and
# ignores untracked files (git+file sees tracked files including uncommitted
# modifications), a modified-but-uncommitted flake.lock is a new key, and
# without Nix it refuses with the bootstrap hint.
# shellcheck source=tests/cli/launcher/helpers.sh
source "$DS_REPO_ROOT/tests/cli/launcher/helpers.sh"

launcher_use_real_nix
# The instance path has a space: the git+file URL must be percent-encoded
# for the real Nix to find it.
inst="$DS_TEST_ROOT/my instance"
launcher_real_instance "$inst"
state=$DOTSTEWARD_STATE_ROOT
key=$(launcher_key "$inst")

# Clean tree: the first call builds and registers the GC root in the
# (isolated) Nix state.
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version --json
assert_eq "fake-cli v1 beta hidden instance=$inst args=version --json" "$DS_STDOUT"
assert_call_count 1 nix '*build*'
assert_call_count 1 nix-store
[[ -L $state/cli/$key ]] || ds_fail "no cache entry for the clean tree"
roots=$(for link in "$launcher_nix_state"/gcroots/auto/*; do readlink "$link"; done)
assert_eq "$state/cli/$key" "$roots" "the cache entry is an indirect GC root"

# A modified tracked file keeps the key; the cached CLI runs, no build.
printf '{ enable = true; }\n' >"$inst/components/alpha/default.nix"
[[ -n $(git -C "$inst" status --porcelain --untracked-files=no) ]] || ds_fail "tree is not dirty"
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli v1 beta hidden instance=$inst args=version" "$DS_STDOUT"
assert_call_count 0 nix
assert_call_count 0 nix-store

# An untracked component directory changes nothing either, and the
# launcher does not refuse it (refusing is the job of the commands that
# evaluate the instance).
mkdir -p "$inst/components/beta"
printf '{ }\n' >"$inst/components/beta/default.nix"
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli v1 beta hidden instance=$inst args=version" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_call_count 0 nix

# A modified, uncommitted flake.lock is a new key and a new build of
# the dirty tree: Nix sees the uncommitted change of the tracked
# message.txt and still does not see the untracked components/beta.
printf 'v2' >"$inst/message.txt"
launcher_write_lock "$inst" 3
key3=$(launcher_key "$inst")
[[ $key3 != "$key" ]] || ds_fail "the modified lock kept the key"
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli v2 beta hidden instance=$inst args=version" "$DS_STDOUT"
assert_call_count 1 nix '*build*'
assert_eq "$(printf '%s\n' "$key" "$key3" | LC_ALL=C sort)" "$(launcher_cache_entries "$state")"
# Both keys stay usable: back to the committed lock is a cache hit again.
git -C "$inst" checkout -q -- flake.lock
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli v1 beta hidden instance=$inst args=version" "$DS_STDOUT"
assert_call_count 0 nix

# No Nix on PATH (the daemon profile adds none) and no cache entry for
# the current lock: the bootstrap hint, exit 1, nothing cached.
no_nix=$(launcher_no_nix_path)
launcher_write_lock "$inst" 4
key4=$(launcher_key "$inst")
: >"$DS_CALL_LOG"
assert_exit 1 env PATH="$no_nix" __ETC_PROFILE_NIX_SOURCED=1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: Nix is required; run ./bootstrap.sh first" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
assert_calls
[[ ! -e $state/cli/$key4 && ! -L $state/cli/$key4 ]] || ds_fail "a cache entry appeared without Nix"
# A cached key still runs without Nix.
launcher_write_lock "$inst" 3
assert_exit 0 env PATH="$no_nix" __ETC_PROFILE_NIX_SOURCED=1 "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli v2 beta hidden instance=$inst args=version" "$DS_STDOUT"
