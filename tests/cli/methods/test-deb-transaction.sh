# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# D3-D5, the deb transaction in fresh mode (SPEC 3.4, D6): every DEB below
# its floor and every missing apt package is collected in [components]
# order, all DEBs are downloaded and verified before the first sudo call,
# then exactly one `apt-get update` and one `apt-get install
# --no-install-recommends <apt> <debs>` run (-y only with
# DOTSTEWARD_ASSUME_YES=1, never --allow-downgrades), and the floors are
# verified afterwards. Current or newer packages are never downloaded; a
# second run is a no-op; hooks still run.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl
app_deb=$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)
term_deb=$(ds_fixture common/debs/example-term_0.9.0_amd64.deb)
app_url=https://downloads.example.invalid/example-app_1.2.3_amd64.deb
term_url=https://downloads.example.invalid/term/stable
pin_download desktop_packages.example-app "$app_deb" "$app_url" 1.2.3
pin_download desktop_packages.example-term "$term_deb" "$term_url" 0.9.0
ds_apt_available alpha 1.0
ds_apt_available beta 2.0
add_component example-term deb '{"pin": "desktop_packages.example-term", "packageNames": ["example-term"], "architecture": "amd64", "verifyAfterInstall": true, "apt": ["alpha", "beta"]}'
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": null, "verifyAfterInstall": true, "apt": ["beta"]}'
add_hook post_install example-app post-install <<EOF
printf '%s\n' "\$DOTSTEWARD_COMPONENT" >>'$DS_TEST_ROOT/post-install-runs'
EOF

# D4: two DEBs below their floors (one installed too old, one missing) and
# a missing apt package; beta is already installed.
ds_dpkg_installed example-app 1.1.0
ds_dpkg_installed beta 2.0
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "1.2.3" "$(ds_dpkg_version example-app)"
assert_eq "0.9.0" "$(ds_dpkg_version example-term)"
assert_eq "1.0" "$(ds_dpkg_version alpha)"

# Downloads first (in [components] order), then the one transaction.
mapfile -t calls < <(grep -E '^(preflight|curl|sudo) ' "$DS_CALL_LOG")
assert_eq "preflight --read-only --json --profile fresh" "${calls[0]}"
assert_contains "${calls[1]}" "curl --proto =https --tlsv1.2 "
assert_contains "${calls[1]}" " $term_url"
assert_contains "${calls[2]}" " $app_url"
assert_eq "sudo apt-get update" "${calls[3]}"
[[ ${calls[4]} == "sudo apt-get install --no-install-recommends alpha $TMPDIR/dotsteward-install."*"/example-term_0.9.0.deb $TMPDIR/dotsteward-install."*"/example-app_1.2.3.deb" ]] ||
  ds_fail "unexpected install call: ${calls[4]}"
assert_eq 5 "${#calls[@]}" "preflight, two downloads, one update, one install"
assert_eq "0" "$(ds_call_count apt-get '*--allow-downgrades*')"
assert_eq "0" "$(ds_call_count apt-get '* -y *')"
assert_contains "$DS_STDOUT" "[dotsteward] installing system packages: alpha example-term_0.9.0.deb example-app_1.2.3.deb"
assert_contains "$DS_STDOUT" "[dotsteward] example-term (deb): installed: example-term 0.9.0, alpha"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-app 1.2.3"
assert_contains "$DS_STDOUT" "[dotsteward] system install verified for profile fresh"
assert_eq "example-app" "$(<"$DS_TEST_ROOT/post-install-runs")"
assert_eq "" "$(temp_dirs)"

# D3: everything current: no download, no apt-get, the hook still runs.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count apt-get)"
assert_contains "$DS_STDOUT" "[dotsteward] example-term (deb): satisfied: example-term 0.9.0"
assert_eq "example-app
example-app" "$(<"$DS_TEST_ROOT/post-install-runs")"

# --json: the same report on standard output, the logs on standard error.
assert_exit 0 run_install --profile fresh --json
assert_json - '.mode == "fresh" and .result == "passed" and ([.components[].status] == ["satisfied", "satisfied"])
  and .hooks == [{"component": "example-app", "name": "post-install", "list": "post_install", "status": "passed", "exit_code": 0}]' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] system install verified for profile fresh"

# D5: a newer installed version than the floor is kept: no download, no
# downgrade. Pre-release ordering follows dpkg.
ds_dpkg_installed example-app 1.3.0
ds_dpkg_installed example-term 0.9.0~rc1
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "1.3.0" "$(ds_dpkg_version example-app)"
assert_eq "1" "$(ds_call_count curl)"
assert_contains "$(ds_calls_of curl)" "$term_url"
assert_eq "0.9.0" "$(ds_dpkg_version example-term)"

# DOTSTEWARD_ASSUME_YES=1 adds -y (CI and VM only).
ds_dpkg_installed example-term 0.8.0
: >"$DS_CALL_LOG"
export DOTSTEWARD_ASSUME_YES=1
assert_exit 0 run_install --profile fresh
unset DOTSTEWARD_ASSUME_YES
assert_eq "1" "$(ds_call_count sudo 'apt-get install -y --no-install-recommends *')"

# An apt-only component (no pin) adds its packages to the same transaction.
manifest_edit '.components = []'
add_component example-app deb '{"pin": null, "packageNames": [], "architecture": null, "verifyAfterInstall": true, "apt": ["gamma"]}'
ds_apt_available gamma 3.0
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "sudo apt-get update
sudo apt-get install --no-install-recommends gamma" "$(ds_calls_of sudo)"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "3.0" "$(ds_dpkg_version gamma)"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: gamma"
