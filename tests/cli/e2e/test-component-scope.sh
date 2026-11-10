# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward e2e --component NAME` (repeatable): only the checks of the named components
# (their hooks of every phase and their agent rules), in run order, for a command that
# checks a few components after a change of their packages, such as `observe`. Such a run
# is no run of the machine: it writes no record of E2E, so `txn publish` and the E2E key
# of `upgrade` never take it for a full one. A name that is no active component of the
# profile is an error.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

record=$DOTSTEWARD_STATE_ROOT/update/e2e.json
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
add_component gamma external "$none" '["fresh"]'
for phase in early main late; do
  hook_log_script "app-$phase" | add_e2e_hook example-app "app-$phase" "$phase"
  hook_log_script "term-$phase" | add_e2e_hook example-term "term-$phase" "$phase"
done
publish_instance

assert_exit 0 run_e2e --component example-app --list
assert_eq "example-app:app-early
example-app:app-main
example-app:app-late" "$DS_STDOUT"
assert_exit 0 run_e2e --component example-app --component example-term --list --json
assert_json - '.checks == ["example-term:term-early", "example-app:app-early", "example-term:term-main",
  "example-app:app-main", "example-term:term-late", "example-app:app-late"]' <<<"$DS_STDOUT"

# Only the hooks of the named component run, and nothing is recorded.
assert_exit 0 run_e2e --component example-app
assert_eq "app-early example-app/workstation/adopt/1
app-main example-app/workstation/adopt/1
app-late example-app/workstation/adopt/1" "$(<"$e2e_hook_log")"
[[ ! -e $record ]] || ds_fail "a run of some components wrote the record of E2E"

# A failing check of the component is a finding of that component.
: >"$e2e_hook_log"
printf 'exit 4\n' | add_e2e_hook example-app app-broken main
assert_exit 1 run_e2e --component example-app --component example-term --keep-going --json
assert_eq '[["example-app:app-broken","hook-failed","example-app/app-broken"]]' "$(findings)"
assert_eq 'failed' "$(jq -r .result <<<"$DS_STDOUT")"
[[ ! -e $record ]] || ds_fail "a failed run of some components wrote the record of E2E"

# The full run still records.
assert_exit 1 run_e2e --keep-going
[[ -e $record ]] || ds_fail "a full run wrote no record"

# A name outside the active components of the profile.
assert_exit 1 run_e2e --component gamma
assert_contains "$DS_STDERR" "e2e: --component gamma: not an active component of profile workstation"
assert_exit 1 run_e2e --component no-such-component --list
assert_contains "$DS_STDERR" "e2e: --component no-such-component: not an active component of profile workstation"
assert_exit 1 run_e2e --component
assert_contains "$DS_STDERR" "e2e: --component requires a value"
