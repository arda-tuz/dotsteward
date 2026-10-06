# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# D2, fresh mode: `install` runs `dotsteward preflight --read-only --json
# --profile P` first; the adaptive route (exit 3) and any other failure stop
# the phase with the preflight's status, before any package query,
# download, sudo call, hook or write. --check-only never runs the preflight.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs --all
pin_download desktop_packages.example-app "$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)" \
  https://downloads.example.invalid/example-app_1.2.3_amd64.deb 1.2.3
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": null, "verifyAfterInstall": true, "apt": ["alpha"]}'
add_hook system_install example-app system-install <<EOF
touch '$DS_TEST_ROOT/hook-ran'
EOF
: >"$DS_CALL_LOG"

preflight_exit 3
assert_exit 3 run_install --profile fresh
assert_calls "preflight --read-only --json --profile fresh"
[[ ! -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "a hook ran after the adaptive route"
assert_eq "" "$(temp_dirs)"
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT" -mindepth 1 -print)"

: >"$DS_CALL_LOG"
preflight_exit 1
assert_exit 1 run_install --profile fresh
assert_calls "preflight --read-only --json --profile fresh"

# The preflight's JSON never reaches install's own standard output.
: >"$DS_CALL_LOG"
preflight_exit 3
assert_exit 3 run_install --profile fresh --json
assert_eq "" "$DS_STDOUT"

# --check-only is read-only and needs no preflight.
: >"$DS_CALL_LOG"
preflight_exit 3
ds_dpkg_installed example-app 1.2.3
ds_dpkg_installed alpha 1.0
assert_exit 0 run_install --profile fresh --check-only
assert_eq "0" "$(ds_call_count preflight)"
assert_eq "0" "$(ds_call_count sudo)"
