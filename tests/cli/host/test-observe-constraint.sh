# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward observe` and the version rules of deb components. When the owner moves a package of
# a constrained component outside its constraint with their own apt, or a package of a component to
# or above the component hold of the host file of this machine, the observer says so as the apt plan
# of `upgrade` does (`constraint-left-by-owner`), once for that change: a note, never red, no
# desktop notification, and the package stays where the owner put it. A move inside the rule and a
# package of a component without a rule say nothing.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

add_component example-server deb '{"packageNames": ["example-server", "example-server-client"]}'
add_component example-editor deb '{"packageNames": ["example-editor"]}'
add_component example-viewer deb '{"packageNames": ["example-viewer"]}'
hook_log_script server-runs | add_e2e_hook example-server server-runs main
sed -i '/^\[components\.example-server\]$/a version = "16.*"\nreason = "the data directory is of 16"' \
  "$agents_inst/workstation.toml"
write_host laptop '
[holds."component:example-editor"]
version = "3"
reason = "the plugins of example-editor need 2.x"'
publish_instance "chore: a constrained component and a held one"

pkg example-server 16.4-1
pkg example-server-client 16.4-1
pkg example-editor 2.5-1
pkg example-viewer 5.0-1
name_machine laptop
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "the first observation: the installed packages are the baseline"
assert_not_contains "$DS_STDOUT" "constraint-left-by-owner"

nothing_changed_by_observer() {
  assert_eq "" "$(ds_calls_of dpkg | grep -v -e '^dpkg --audit$' -e '^dpkg --print-architecture$' || true)" \
    "the observer ran dpkg for more than reading"
  assert_eq "" "$(ds_calls_of sudo)" "the observer ran sudo"
  assert_eq "" "$(ds_calls_of notify-send)" "a note notified the desktop"
}

# --- a move inside the constraint: nothing to say ---------------------------------------

pkg example-server 16.5-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-server: verified at 16.5-1 (changed: example-server)"
assert_not_contains "$DS_STDOUT" "constraint-left-by-owner"

# --- the owner takes the server to 17: said, never red, nothing undone ------------------

pkg example-server 17.0-1
pkg example-server-client 17.0-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "constraint-left-by-owner: example-server 17.0-1 is outside constraint 16.* of example-server: the owner took it there, and dotsteward leaves it as it is"
assert_contains "$DS_STDOUT" "constraint-left-by-owner: example-server-client 17.0-1 is outside constraint 16.* of example-server"
assert_contains "$DS_STDOUT" "example-server: verified at 17.0-1"
assert_eq '"verified"' "$(shown '.state.components["example-server"].status')"
assert_eq '"17.0-1"' "$(shown '.state.components["example-server"].packages["example-server"]')"
nothing_changed_by_observer

# Said once for that change: the next run has nothing new to say.
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"
assert_not_contains "$DS_STDOUT" "constraint-left-by-owner"

# --- the hold of the host file, and a component without a rule --------------------------

pkg example-editor 3.1-1
pkg example-viewer 6.0-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "constraint-left-by-owner: example-editor 3.1-1 is outside hold 3 of example-editor: the owner took it there, and dotsteward leaves it as it is"
assert_not_contains "$DS_STDOUT" "example-viewer 6.0-1 is outside"
assert_not_contains "$DS_STDOUT" "example-server 17.0-1 is outside"
nothing_changed_by_observer
