# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# core:observer: on Linux, when the generation has the observer (its path unit is a managed
# link), `dotsteward e2e` checks that the user manager runs dotsteward-observe.path. Until
# the first activation of such a generation reaches the user manager it only reports: no
# user manager to ask (a container, a session without one), no systemctl, or a unit the
# user manager has not loaded yet (the next login or `rebuild --switch` starts it) is a
# warning. A loaded path unit that is not active is the one finding: package changes go
# unnoticed. A run of some components (--component) does not run it.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

ds_use_stubs systemctl
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
publish_instance

# Without the observer in the generation there is nothing to check.
assert_exit 0 run_e2e --list
assert_not_contains "$DS_STDOUT" "core:observer"

# What the activation of a generation with the observer leaves behind.
units=$HOME/.config/systemd/user
store=$DS_TEST_ROOT/hm-store
mkdir -p "$store" "$units/default.target.wants"
printf '[Path]\nPathChanged=/var/lib/dpkg/status\n' >"$store/dotsteward-observe.path"
printf '[Service]\nType=exec\n' >"$store/dotsteward-observe.service"
for unit in dotsteward-observe.path dotsteward-observe.service; do
  ln -s "$store/$unit" "$units/$unit"
  ln -s "$store/$unit" "$units/default.target.wants/$unit"
done
manifest_edit '.managed_links = [
  "~/.config/systemd/user/dotsteward-observe.path", "~/.config/systemd/user/dotsteward-observe.service",
  "~/.config/systemd/user/default.target.wants/dotsteward-observe.path",
  "~/.config/systemd/user/default.target.wants/dotsteward-observe.service"]'
publish_instance

assert_exit 0 run_e2e --list
assert_contains "$DS_STDOUT" "core:observer"
assert_exit 0 run_e2e --component example-app --list
assert_not_contains "$DS_STDOUT" "core:observer"

# No user manager to ask: a warning.
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:observer: the user manager is not reachable; dotsteward-observe.path was not checked"

# No systemctl: a warning.
assert_exit 0 env PATH="$(ds_path_without systemctl)" "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  e2e --profile workstation </dev/null
assert_contains "$DS_STDERR" "core:observer: no systemctl; dotsteward-observe.path was not checked"

# The user manager has not loaded the unit yet: a warning that names the way.
ds_stub_set systemctl user-manager running
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:observer: the user manager has not loaded dotsteward-observe.path yet; the next login or 'dotsteward rebuild --profile workstation --switch' starts it"

# Loaded but not active: the one finding.
assert_exit 0 systemctl --user daemon-reload
assert_exit 1 run_e2e --json
assert_eq '[["core:observer","observer-inactive","dotsteward-observe.path"]]' "$(findings)"
assert_contains "$DS_STDOUT" "dotsteward-observe.path is inactive: package changes outside dotsteward go unnoticed"

# Active: green, and no warning.
assert_exit 0 systemctl --user start dotsteward-observe.path
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:observer"
