# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rebuild --framework-override REF: the build overrides the
# framework input of the instance in memory (--override-input
# <host_input>/dotsteward REF), together with the instance input itself
# (path:<checkout>), so a stale host lock never builds an old instance tree;
# nothing is written to a lock (--no-write-lock-file) and the host lock is
# neither created nor refreshed. inventory.json records framework_override,
# and the next rebuild without an override refreshes the host lock, because
# the override run did not. DOTSTEWARD_FRAMEWORK_OVERRIDE is the same as the
# flag; the flag wins.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

ref='git+file:///srv/dotsteward?rev=0123456789abcdef0123456789abcdef01234567'
other='path:/srv/other-framework'
build_args() {
  ds_calls_of nix | grep ' build '
}
expected_build="nix --extra-experimental-features nix-command\\ flakes build $rb_hosts#homeConfigurations.current.activationPackage --no-link --override-input dotfiles path:$rb_inst --override-input dotfiles/dotsteward $(printf %q "$ref") --no-write-lock-file --print-out-paths"

# Without a host lock: none is created.
assert_exit 0 run_rebuild --profile workstation --build-only --framework-override "$ref"
assert_contains "$DS_STDOUT" "[dotsteward] framework override $ref: the host input lock is not refreshed"
assert_eq 0 "$(ds_call_count nix '* flake *')"
assert_eq "$expected_build" "$(build_args)"
[[ ! -e $rb_hosts/flake.lock ]] || ds_fail "the override run wrote a host lock"
assert_json "$rb_hosts/inventory.json" ".framework_override == \"$ref\""
[[ -x $(<"$rb_current/last-built-activation")/activate ]] || ds_fail "no activation package recorded"

# A normal run creates the lock; an override run at a new revision leaves it
# byte-identical.
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_eq 1 "$(ds_call_count nix '* flake lock *')"
assert_json "$rb_hosts/inventory.json" '.framework_override == null'
locked=$(host_lock_bytes)
printf '# changed\n' >>"$rb_inst/flake.nix"
instance_commit "new revision"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch --framework-override "$ref"
assert_eq 0 "$(ds_call_count nix '* flake *')"
assert_eq "$locked" "$(host_lock_bytes)"
assert_eq "$expected_build" "$(build_args)"
assert_eq 1 "$(ds_call_count activate)"
assert_json "$rb_hosts/inventory.json" ".framework_override == \"$ref\" and .canonical_revision == \"$(git -C "$rb_inst" rev-parse HEAD)\""

# The next normal run refreshes the lock, even at the same revision.
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDOUT" "[dotsteward] instance source changed; refreshing the host input lock"
assert_eq 1 "$(ds_call_count nix '* flake update dotfiles --flake *')"
assert_json "$rb_hosts/inventory.json" '.framework_override == null'
# And the one after it keeps the lock again.
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_eq 0 "$(ds_call_count nix '* flake *')"

# The environment variable, and the flag over it.
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE="$other" \
  "$rb_fw/cli/dotsteward" --instance "$rb_inst" rebuild --profile workstation --build-only </dev/null
assert_contains "$(build_args)" "--override-input dotfiles/dotsteward $other --no-write-lock-file"
assert_json "$rb_hosts/inventory.json" ".framework_override == \"$other\""
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE="$other" \
  "$rb_fw/cli/dotsteward" --instance "$rb_inst" rebuild --profile workstation --build-only \
  --framework-override "$ref" </dev/null
assert_contains "$(build_args)" "--override-input dotfiles/dotsteward $(printf %q "$ref")"
assert_not_contains "$(build_args)" "$other"
# An empty variable means no override.
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE= \
  "$rb_fw/cli/dotsteward" --instance "$rb_inst" rebuild --profile workstation --build-only </dev/null
assert_contains "$(build_args)" "--no-update-lock-file"
assert_not_contains "$(build_args)" "--override-input"
