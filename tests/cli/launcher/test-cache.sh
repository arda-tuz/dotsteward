# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Launcher cache: key = sha256(flake.lock bytes),
# a miss builds "git+file://<root>#dotsteward" once and registers
# $STATE/cli/<key> as a GC root with nix-store --add-root, a hit execs the
# cached CLI without Nix, at most 5 keys are kept (oldest symlink removed),
# and arguments, exit status and the instance path reach the CLI.
# shellcheck source=tests/cli/launcher/helpers.sh
source "$DS_REPO_ROOT/tests/cli/launcher/helpers.sh"

launcher_use_stub_nix
inst=$DS_TEST_ROOT/instance
launcher_instance "$inst" </dev/null
state=$DOTSTEWARD_STATE_ROOT
key=$(launcher_key "$inst")
[[ $key =~ ^[0-9a-f]{64}$ ]] || ds_fail "unexpected key: $key"

# Miss: one build, one GC root, then the CLI runs with the arguments as given
# and the instance root exported, from any working directory.
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" status --json "two words" ''
assert_eq "fake-cli instance=$inst" "$DS_STDOUT"
out=$(readlink "$state/cli/$key") || ds_fail "no cache entry for $key"
[[ $out == "$DS_STUB_STATE/nix/store/"*-dotsteward ]] || ds_fail "cache entry points to [$out]"
[[ -x $state/cli/$key/bin/dotsteward ]] || ds_fail "cached CLI is not executable"
assert_calls \
  "$(launcher_build_line "$inst")" \
  "$(_ds_call_line nix-store --add-root "$state/cli/$key" --realise "$out")" \
  "$(_ds_call_line dotsteward status --json "two words" '')"
assert_file_mode "$state/cli" 700
assert_eq "$key" "$(launcher_cache_entries "$state")"

# Hit: no Nix call at all, even with Nix missing from PATH.
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_calls "dotsteward version"
no_nix=$(launcher_no_nix_path)
: >"$DS_CALL_LOG"
assert_exit 0 env PATH="$no_nix" __ETC_PROFILE_NIX_SOURCED=1 "$inst/.dotsteward/cli.sh" context --json
assert_eq "fake-cli instance=$inst" "$DS_STDOUT"
assert_calls "dotsteward context --json"

# The CLI's exit status is the launcher's exit status, on a hit and a miss.
LAUNCHER_FAKE_STATUS=3 assert_exit 3 "$inst/.dotsteward/cli.sh" preflight --read-only

# The launcher targets its own instance, whatever DOTSTEWARD_INSTANCE says.
DOTSTEWARD_INSTANCE=$DS_TEST_ROOT/elsewhere assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_eq "fake-cli instance=$inst" "$DS_STDOUT"

# A launcher reached through a symlink still finds its instance.
mkdir -p "$DS_TEST_ROOT/links"
ln -s "$inst/.dotsteward/cli.sh" "$DS_TEST_ROOT/links/dotsteward"
ln -s "$DS_TEST_ROOT/links/dotsteward" "$DS_TEST_ROOT/links/second"
assert_exit 0 "$DS_TEST_ROOT/links/second" version
assert_eq "fake-cli instance=$inst" "$DS_STDOUT"

# A changed flake.lock is a new key: one more build, both entries kept.
launcher_write_lock "$inst" 1
key2=$(launcher_key "$inst")
[[ $key2 != "$key" ]] || ds_fail "different lock bytes gave the same key"
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_call_count 1 nix '*build *'
assert_call_count 1 nix-store
assert_eq "$(printf '%s\n' "$key" "$key2" | LC_ALL=C sort)" "$(launcher_cache_entries "$state")"

# A stale entry (its store path is gone) is rebuilt and replaced.
ln -sfn "$DS_TEST_ROOT/gone" "$state/cli/$key2"
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_call_count 1 nix '*build *'
assert_eq "$out" "$(readlink "$state/cli/$key2")"

# At most 5 keys: the entry with the oldest symlink mtime goes, whatever its
# name or creation order; files that are not cache keys are left alone.
rm -rf -- "$state/cli"
keys=()
for n in 1 2 3 4 5; do
  launcher_write_lock "$inst" "$n"
  keys+=("$(launcher_key "$inst")")
  assert_exit 0 "$inst/.dotsteward/cli.sh" version
done
assert_eq 5 "$(launcher_cache_entries "$state" | wc -l | tr -d ' ')"
stamps=(201 203 199 204 202)
for i in 0 1 2 3 4; do
  touch -h -d "@$((1700000000 + stamps[i]))" "$state/cli/${keys[i]}"
done
printf 'not a key\n' >"$state/cli/README"
ln -s "$DS_TEST_ROOT/gone" "$state/cli/not-a-key"
launcher_write_lock "$inst" 6
key6=$(launcher_key "$inst")
: >"$DS_CALL_LOG"
assert_exit 0 "$inst/.dotsteward/cli.sh" version
assert_call_count 1 nix '*build *'
expected=$(printf '%s\n' "${keys[0]}" "${keys[1]}" "${keys[3]}" "${keys[4]}" "$key6" README not-a-key |
  LC_ALL=C sort)
assert_eq "$expected" "$(launcher_cache_entries "$state")" "the oldest key (third) is evicted"
assert_eq "not a key" "$(<"$state/cli/README")"

# Nix found only in ~/.nix-profile/bin (single-user install) is used.
mkdir -p "$HOME/.nix-profile/bin"
ln -s "$DS_TEST_ROOT/bin/nix" "$HOME/.nix-profile/bin/nix"
ln -s "$DS_TEST_ROOT/bin/nix-store" "$HOME/.nix-profile/bin/nix-store"
launcher_write_lock "$inst" 7
: >"$DS_CALL_LOG"
assert_exit 0 env PATH="$no_nix" __ETC_PROFILE_NIX_SOURCED=1 "$inst/.dotsteward/cli.sh" version
assert_call_count 1 nix '*build *'
rm -rf -- "$HOME/.nix-profile"

# A failed build propagates its status, says so and caches nothing.
launcher_write_lock "$inst" 8
key8=$(launcher_key "$inst")
ds_stub_route nix 'build *' --exit 7 --stderr "error: builder failed" --times 1
: >"$DS_CALL_LOG"
assert_exit 7 "$inst/.dotsteward/cli.sh" version
assert_contains "$DS_STDERR" "error: builder failed"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
assert_eq "" "$DS_STDOUT"
[[ ! -e $state/cli/$key8 && ! -L $state/cli/$key8 ]] || ds_fail "a failed build left a cache entry"
assert_call_count 0 nix-store
assert_call_count 0 dotsteward

# A build that prints no usable CLI is refused before anything is cached.
mkdir -p "$DS_TEST_ROOT/empty-output"
ds_stub_route nix 'build *' --stdout "$DS_TEST_ROOT/empty-output" --times 1
: >"$DS_CALL_LOG"
assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
assert_contains "$DS_STDERR" "bin/dotsteward"
[[ ! -e $state/cli/$key8 && ! -L $state/cli/$key8 ]] || ds_fail "an unusable build was cached"
assert_call_count 0 nix-store

# Without flake.lock there is no key: a clear refusal, no Nix call.
rm -- "$inst/flake.lock"
: >"$DS_CALL_LOG"
assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: flake.lock not found in $inst; the launcher needs the instance lock file" \
  "$DS_STDERR"
assert_calls

# An instance path with a space and URL metacharacters is percent-encoded in
# the git+file URL.
odd="$DS_TEST_ROOT/odd dir#1?x%y"
launcher_instance "$odd" </dev/null
: >"$DS_CALL_LOG"
assert_exit 0 "$odd/.dotsteward/cli.sh" version
assert_eq "fake-cli instance=$odd" "$DS_STDOUT"
assert_eq "$(launcher_build_line "$odd")" "$(ds_calls_of nix)"
assert_contains "$(ds_calls_of nix)" "odd%20dir%231%3Fx%25y#dotsteward"
