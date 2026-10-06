# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The host lock memo (SPEC 6.2, F5, I-4): the host input lock is created
# when missing, kept byte-identical while (canonical_revision,
# canonical_repo) of inventory.json match the instance, and refreshed with
# `nix flake update <host_input>` when the revision or the checkout path
# changes or inventory.json is unreadable. The instance flake.lock is never
# changed.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

update_call="nix --extra-experimental-features nix-command\\ flakes flake update dotfiles --flake $rb_hosts"
instance_lock=$(sha256sum "$rb_inst/flake.lock")

# First run: the lock is created.
assert_exit 0 run_rebuild --profile workstation --build-only
assert_eq 1 "$(ds_call_count nix '* flake lock *')"
assert_eq 0 "$(ds_call_count nix '* flake update *')"
first=$(host_lock_bytes)
assert_eq '{ "host-lock": 1 }' "$first"

# Same revision and checkout: kept.
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDOUT" "[dotsteward] instance source unchanged; keeping the host input lock"
assert_eq 0 "$(ds_call_count nix '* flake *')"
assert_eq "$first" "$(host_lock_bytes)"
# --switch at the same revision keeps it too.
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_eq 0 "$(ds_call_count nix '* flake *')"
assert_eq "$first" "$(host_lock_bytes)"

# A new commit: refreshed.
printf '# second\n' >>"$rb_inst/flake.nix"
instance_commit "second revision"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDOUT" "[dotsteward] instance source changed; refreshing the host input lock"
assert_eq "$update_call" "$(ds_calls_of nix | grep ' flake ')"
assert_eq '{ "host-lock": 2 }' "$(host_lock_bytes)"
assert_json "$rb_hosts/inventory.json" ".canonical_revision == \"$(git -C "$rb_inst" rev-parse HEAD)\""

# An unreadable inventory: refreshed, then rewritten.
printf 'not json\n' >"$rb_hosts/inventory.json"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_eq "$update_call" "$(ds_calls_of nix | grep ' flake ')"
assert_json "$rb_hosts/inventory.json" '.schema_version == "1.0"'

# A moved checkout (same revision): refreshed, and the host flake names the
# new path.
moved=$DS_TEST_ROOT/moved
cp -R "$rb_inst" "$moved"
: >"$DS_CALL_LOG"
assert_exit 0 "$rb_fw/cli/dotsteward" --instance "$moved" rebuild --profile workstation --build-only </dev/null
assert_eq "$update_call" "$(ds_calls_of nix | grep ' flake ')"
assert_contains "$(<"$rb_hosts/flake.nix")" "inputs.dotfiles.url = \"path:$moved\";"
assert_json "$rb_hosts/inventory.json" ".canonical_repo == \"$moved\""

# A host lock deleted by hand: created again.
rm -f -- "$rb_hosts/flake.lock"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_eq 1 "$(ds_call_count nix '* flake lock *')"
assert_file_mode "$rb_hosts/flake.lock" 600

assert_eq "$instance_lock" "$(sha256sum "$rb_inst/flake.lock")"

# A lock command that writes nothing is an error, not a silent success.
rm -f -- "$rb_hosts/flake.lock"
: >"$DS_TEST_ROOT/lock-noop"
assert_exit 1 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the host input lock was not written: $rb_hosts/flake.lock"
