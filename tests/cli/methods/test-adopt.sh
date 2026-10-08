# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Adopt mode: `install` skips the system-install phase with
# one log line naming the system-level components, before the preflight and
# before any command requirement: no stub is called, no hook runs, nothing
# is written. `--check-only` reports system-level methods as not-managed
# (never a version failure) and still checks the user-level ones.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs --all
ds_dpkg_installed example-app 1.1.0
pin_download desktop_packages.example-app "$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)" \
  https://downloads.example.invalid/example-app_1.2.3_amd64.deb 1.2.3
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": "amd64", "verifyAfterInstall": true, "apt": ["alpha"]}'
add_component example-term external '{"command": "example-term", "versionArgv": ["--version"], "minimum": null}'
add_hook post_install example-app post-install <<EOF
touch '$DS_TEST_ROOT/post-install-ran'
EOF
add_hook forbid example-app forbid <<EOF
touch '$DS_TEST_ROOT/forbid-ran'
EOF
: >"$DS_CALL_LOG"

assert_exit 0 run_install --profile workstation
assert_eq "[dotsteward] workstation (adopt mode): system install skipped; not managed: example-app" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_calls
[[ ! -e $DS_TEST_ROOT/post-install-ran && ! -e $DS_TEST_ROOT/forbid-ran ]] || ds_fail "a hook ran in adopt mode"
assert_eq "" "$(temp_dirs)"
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print)"

# Without system-level components the line has no list.
manifest_edit '.components |= map(select(.name != "example-app"))'
assert_exit 0 run_install --profile workstation
assert_eq "[dotsteward] workstation (adopt mode): system install skipped" "$DS_STDOUT"
assert_calls

# The JSON report lists every active component.
manifest_edit '.components = []'
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": null, "verifyAfterInstall": true, "apt": []}'
add_component example-term external '{"command": "example-term", "versionArgv": ["--version"], "minimum": null}'
assert_exit 0 run_install --profile workstation --json
assert_eq "[dotsteward] workstation (adopt mode): system install skipped; not managed: example-app" "$DS_STDERR"
assert_json - '.schema_version == 1 and .profile == "workstation" and .mode == "adopt" and .check_only == false and .result == "passed"' <<<"$DS_STDOUT"
assert_json - '.components == [
  {"name": "example-app", "method": "deb", "status": "not-managed", "detail": "system-level method in adopt mode"},
  {"name": "example-term", "method": "external", "status": "skipped", "detail": "not installed by dotsteward"}
] and .hooks == []' <<<"$DS_STDOUT"
assert_calls

# --check-only: the deb component is not managed even though it is below its
# floor; the external one is checked.
assert_exit 0 run_install --profile workstation --check-only
assert_eq "[dotsteward] example-app (deb): not-managed: system-level method in adopt mode
[dotsteward] example-term (external): satisfied: example-term found" "$DS_STDOUT"
assert_eq "0" "$(ds_call_count dpkg-query)"
assert_eq "0" "$(ds_call_count preflight)"
assert_eq "0" "$(ds_call_count sudo)"
[[ ! -e $DS_TEST_ROOT/forbid-ran ]] || ds_fail "a forbid hook ran in adopt mode"

assert_exit 0 run_install --profile workstation --check-only --json
assert_json - '.check_only == true and .result == "passed" and ([.components[].status] == ["not-managed", "satisfied"])' <<<"$DS_STDOUT"
