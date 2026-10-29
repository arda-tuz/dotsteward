# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `install --component NAME` (repeatable) limits the run to the named
# components of the profile. On an adopted machine it is how a new
# system-level component is brought in without the rest of a fresh install:
# the preflight gate, the deb transaction of the named components only and
# only their hooks run; every other component stays untouched.
# --check-only with --component checks the named components by their
# method, also in adopt mode. A name that is not active in the profile is
# refused before any step.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl
app_url=https://downloads.example.invalid/example-app_1.2.3_amd64.deb
pin_download desktop_packages.example-app "$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)" "$app_url" 1.2.3
ds_apt_available alpha 1.0
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": "amd64", "verifyAfterInstall": true, "apt": []}'
add_component example-term deb '{"pin": null, "packageNames": [], "architecture": null, "verifyAfterInstall": true, "apt": ["alpha"]}'
add_hook post_install example-app post-install <<EOF
printf '%s %s\n' "\$DOTSTEWARD_COMPONENT" "\$DOTSTEWARD_PROFILE_MODE" >>'$DS_TEST_ROOT/hook-runs'
EOF
add_hook post_install example-term post-install <<EOF
printf '%s %s\n' "\$DOTSTEWARD_COMPONENT" "\$DOTSTEWARD_PROFILE_MODE" >>'$DS_TEST_ROOT/hook-runs'
EOF

# A name that is not an active component is refused before any step.
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile workstation --component example-nope
assert_contains "$DS_STDERR" "install: example-nope is not an active component of profile workstation"
assert_calls

# Adopt mode with --component: the named component is installed like in
# fresh mode, the other one and its hook are left alone.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation --component example-app
assert_contains "$DS_STDOUT" "[dotsteward] workstation (adopt mode): installing the named components: example-app"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-app 1.2.3"
assert_not_contains "$DS_STDOUT" "example-term"
assert_eq "1.2.3" "$(ds_dpkg_version example-app)"
assert_eq "" "$(ds_dpkg_version alpha)"
assert_eq "example-app adopt" "$(<"$DS_TEST_ROOT/hook-runs")"
mapfile -t calls < <(grep -E '^(preflight|curl|sudo) ' "$DS_CALL_LOG")
assert_eq "preflight --read-only --json --profile workstation" "${calls[0]}"
assert_contains "${calls[1]}" " $app_url"
assert_eq "sudo timeout 600 apt-get update" "${calls[2]}"
[[ ${calls[3]} == "sudo apt-get install --no-install-recommends $TMPDIR/dotsteward-install."*"/example-app_1.2.3.deb" ]] ||
  ds_fail "unexpected install call: ${calls[3]}"
assert_eq 4 "${#calls[@]}"

# --check-only with --component checks the named component by its method,
# also in adopt mode; without --component it stays not-managed.
assert_exit 0 run_install --profile workstation --check-only --component example-app
assert_eq "[dotsteward] example-app (deb): satisfied: example-app 1.2.3" "$DS_STDOUT"
assert_exit 1 run_install --profile workstation --check-only --component example-term
assert_contains "$DS_STDERR" "example-term (deb): apt package alpha is not installed"
assert_exit 0 run_install --profile workstation --check-only
assert_contains "$DS_STDOUT" "[dotsteward] example-term (deb): not-managed: system-level method in adopt mode"

# Fresh mode with --component runs only the named components too; the JSON
# report lists only them.
rm -f -- "$DS_TEST_ROOT/hook-runs"
assert_exit 0 run_install --profile fresh --component example-term --json
assert_json - '.result == "passed" and ([.components[].name] == ["example-term"]) and ([.hooks[].component] == ["example-term"])' <<<"$DS_STDOUT"
assert_eq "1.0" "$(ds_dpkg_version alpha)"
assert_eq "example-term fresh" "$(<"$DS_TEST_ROOT/hook-runs")"

# Two names, in [components] order whatever the order on the command line.
rm -f -- "$DS_TEST_ROOT/hook-runs"
assert_exit 0 run_install --profile workstation --component example-term --component example-app
assert_eq "example-app adopt
example-term adopt" "$(<"$DS_TEST_ROOT/hook-runs")"
assert_contains "$DS_STDOUT" "installing the named components: example-app, example-term"
