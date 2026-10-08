# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# The external method: dotsteward installs nothing; the check is
# an optional `command -v` and an optional floor read from a lock path (a
# version string, or an entry with minimum_version or version), compared as
# dotted versions with the output of versionArgv (default --version). The
# app-archive method is a darwin method; on Linux it is refused.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs example-app example-term
add_component example-app external '{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external '{"command": "example-term", "versionArgv": null, "minimum": "tools.example-term"}'
lock_set tools.example-term '"0.9.0"'

check_term() {
  in_methods_shell 'methods_check example-term fresh && status=0 || status=$?
    printf "%s %s: %s\n" "$status" "$METHODS_STATUS" "$METHODS_DETAIL"'
}

assert_exit 0 run_install --profile fresh --check-only
assert_eq "[dotsteward] example-app (external): satisfied: nothing to check
[dotsteward] example-term (external): satisfied: example-term 0.9.0" "$DS_STDOUT"
assert_eq "example-term --version" "$(ds_calls_of example-term)"

# Floors compare dotted versions numerically, pre-releases sort first.
for case in "0.10.0 0 satisfied" "0.9.1 0 satisfied" "0.9.0 0 satisfied" "0.8.9 1 failed" \
  "0.9.0-rc.1 1 failed" "1.0 0 satisfied" "0.9 1 failed"; do
  read -r reported status word <<<"$case"
  ds_stub_set example-term version "example-term $reported (build 2026-01-02)"
  assert_exit 0 check_term
  assert_contains "$DS_STDOUT" "$status $word: " "example-term $reported against 0.9.0"
done

# A floor entry, a versionArgv, an object without a version.
lock_set tools.example-term '{"minimum_version": "2.0.0", "notes": "x"}'
manifest_edit '(.components[] | select(.name == "example-term") | .install.versionArgv) = ["version", "--short"]'
ds_stub_set example-term version "2.1.0"
: >"$DS_CALL_LOG"
assert_exit 0 check_term
assert_eq "0 satisfied: example-term 2.1.0" "$DS_STDOUT"
assert_eq "example-term version --short" "$(ds_calls_of example-term)"
lock_set tools.example-term '{"notes": "x"}'
assert_exit 1 check_term
assert_eq "[dotsteward] ERROR: example-term (external): versions.lock.json tools.example-term is not a version (a string, or an entry with minimum_version or version)" "$DS_STDERR"

# A floor needs a command.
lock_set tools.example-term '"1.0.0"'
manifest_edit '(.components[] | select(.name == "example-term") | .install.command) = null'
assert_exit 1 check_term
assert_eq "[dotsteward] ERROR: example-term (external): a minimum needs a command" "$DS_STDERR"

# A command without a floor is only looked up.
manifest_edit '(.components[] | select(.name == "example-term") | .install) = {"command": "example-term", "versionArgv": null, "minimum": null}'
: >"$DS_CALL_LOG"
assert_exit 0 check_term
assert_eq "0 satisfied: example-term found" "$DS_STDOUT"
assert_calls

# app-archive is not available on Linux, in either mode of the command.
manifest_edit '.components = []'
add_component example-app app-archive '{"pin": "apps.example-app", "appName": "Example App.app", "dest": "~/Applications"}'
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-app (app-archive): the app-archive method is not available on linux" "$DS_STDERR"
preflight_exit 0
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: example-app (app-archive): the app-archive method is not available on linux" "$DS_STDERR"
# In adopt mode it is a system-level method: not managed.
assert_exit 0 run_install --profile workstation --check-only
assert_eq "[dotsteward] example-app (app-archive): not-managed: system-level method in adopt mode" "$DS_STDOUT"

# An unknown method in the manifest is refused.
manifest_edit '.components[0].method = "teleport"'
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-app: unknown install method: teleport" "$DS_STDERR"
