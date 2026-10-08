# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Flag matrix of `dotsteward e2e`: a required --profile
# of the instance, --expected-remote-base OID (40 lowercase hex digits, not
# with --skip-repo-checks), --framework-override REF (or
# DOTSTEWARD_FRAMEWORK_OVERRIDE), --generation PATH (a directory),
# --keep-going, --json, --list and --skip-repo-checks. Usage errors exit 1
# before any check runs; --help names every flag. An instance that matches
# its contract passes with the success line, and --json prints exactly one
# document on standard output.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

e2e() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e "$@" </dev/null
}

assert_exit 0 e2e --help
for flag in --profile --expected-remote-base --framework-override --generation --keep-going --json \
  --list --skip-repo-checks; do
  assert_contains "$DS_STDOUT" "$flag"
done
assert_exit 0 "$agents_fw/cli/dotsteward" --help
assert_contains "$DS_STDOUT" "e2e"
assert_contains "$DS_STDOUT" "component"

# A hook that would record every run proves that usage errors run nothing.
hook_log_script early-check | add_e2e_hook example-app early-check early
add_component example-app external '{"command": null, "versionArgv": null, "minimum": null}'
publish_instance
: >"$DS_FAKESSH_LOG"
oid=$(git -C "$agents_inst" rev-parse HEAD)

assert_exit 1 e2e
assert_contains "$DS_STDERR" "e2e: --profile is required"
assert_exit 1 e2e --profile
assert_contains "$DS_STDERR" "e2e: --profile requires a value"
assert_exit 1 e2e --profile elsewhere
assert_contains "$DS_STDERR" "unsupported profile: elsewhere"
assert_exit 1 e2e --profile workstation --verbose
assert_contains "$DS_STDERR" "e2e: unknown option: --verbose"
assert_exit 1 e2e --profile workstation now
assert_contains "$DS_STDERR" "e2e: unexpected argument: now"
assert_exit 1 e2e --profile workstation --expected-remote-base 1234abc
assert_contains "$DS_STDERR" "e2e: invalid --expected-remote-base OID: 1234abc"
assert_exit 1 e2e --profile workstation --expected-remote-base "${oid^^}"
assert_contains "$DS_STDERR" "invalid --expected-remote-base OID"
assert_exit 1 e2e --profile workstation --expected-remote-base "$oid" --skip-repo-checks
assert_contains "$DS_STDERR" "e2e: --expected-remote-base cannot be combined with --skip-repo-checks"
assert_exit 1 e2e --profile workstation --generation "$DS_TEST_ROOT/missing"
assert_contains "$DS_STDERR" "e2e: generation not found: $DS_TEST_ROOT/missing"
assert_exit 1 e2e --profile workstation --framework-override ''
assert_contains "$DS_STDERR" "e2e: --framework-override requires a value"
assert_exit 1 env USER='Not Safe' "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation
assert_contains "$DS_STDERR" "unsafe user name"
assert_eq "" "$(<"$e2e_hook_log")" "usage errors run no hook"
assert_eq "" "$(<"$DS_FAKESSH_LOG")" "usage errors reach no remote"

# The instance matches its contract: every check passes.
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile workstation)"
assert_eq "early-check example-app/workstation/adopt/1" "$(<"$e2e_hook_log")"
assert_contains "$(<"$DS_FAKESSH_LOG")" "git-upload-pack"
assert_exit 0 run_e2e --profile=fresh
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile fresh)"

# --json: one document on standard output, logs on standard error.
assert_exit 0 run_e2e --json
assert_eq '{"result":"passed","findings":[]}' "$(jq -c . <<<"$DS_STDOUT")"
assert_eq 1 "$(jq -s length <<<"$DS_STDOUT")"
assert_contains "$DS_STDERR" "[dotsteward] e2e checks passed (profile workstation)"

# The pre-publish base and the framework override are accepted.
assert_exit 0 run_e2e --expected-remote-base "$oid"
assert_exit 0 run_e2e --framework-override "git+file://$DS_TEST_ROOT/clone?rev=$oid"
assert_contains "$DS_STDOUT" "framework override: git+file://$DS_TEST_ROOT/clone?rev=$oid"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE="path:$DS_TEST_ROOT/clone" \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation
assert_contains "$DS_STDOUT" "framework override: path:$DS_TEST_ROOT/clone"

# --skip-repo-checks (CI fixtures): a dirty instance without a reachable
# remote still passes.
printf 'scratch\n' >"$agents_inst/scratch.txt"
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "instance checkout is not clean"
assert_exit 0 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e \
  --profile workstation --skip-repo-checks
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile workstation)"
assert_eq "" "$(temp_dirs)" "no temporary directory is left behind"
