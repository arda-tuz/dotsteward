# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Deb refusals: a non-HTTPS URL, a failed download, a size or digest
# mismatch, a wrong Package or Architecture field each stop the phase with
# their own message before any sudo call, and the temporary directory is
# removed. Package aliases are accepted. A floor that still fails after the
# transaction stops the phase unless verifyAfterInstall is false. A failed
# apt-get update or apt-get install stops the phase with its own message.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl
app_deb=$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)
old_deb=$(ds_fixture common/debs/example-app_1.1.0_amd64.deb)
term_deb=$(ds_fixture common/debs/example-term_0.9.0_amd64.deb)
term_url=https://downloads.example.invalid/example-term_0.9.0_amd64.deb
app_url=https://downloads.example.invalid/example-app_1.2.3_amd64.deb
pin_download desktop_packages.example-term "$term_deb" "$term_url" 0.9.0
pin_download desktop_packages.example-app "$app_deb" "$app_url" 1.2.3
add_component example-term deb '{"pin": "desktop_packages.example-term", "packageNames": ["example-term"], "architecture": "amd64", "verifyAfterInstall": true, "apt": []}'
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": null, "verifyAfterInstall": true, "apt": []}'
add_hook post_install example-app post-install <<EOF
touch '$DS_TEST_ROOT/hook-ran'
EOF

# expect_refusal MESSAGE: install fails with MESSAGE, without sudo, hooks or
# a temporary directory left behind, and nothing was installed.
expect_refusal() {
  : >"$DS_CALL_LOG"
  assert_exit 1 run_install --profile fresh
  assert_eq "[dotsteward] ERROR: $1" "${DS_STDERR##*$'\n'}"
  assert_eq "0" "$(ds_call_count sudo)"
  [[ ! -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "a hook ran after a refusal"
  assert_eq "" "$(temp_dirs)"
  assert_eq "" "$(ds_dpkg_version example-app)$(ds_dpkg_version example-term)"
}

# The second download fails after the first one succeeded.
lock_set desktop_packages.example-app.url '"http://downloads.example.invalid/example-app_1.2.3_amd64.deb"'
expect_refusal "example-app (deb): refusing a non-HTTPS download URL: http://downloads.example.invalid/example-app_1.2.3_amd64.deb"
assert_eq "1" "$(ds_call_count curl)"

lock_set desktop_packages.example-app.url "\"$app_url\""
ds_curl_serve "$app_url" "$app_deb" 404
expect_refusal "example-app (deb): download failed (curl exit 22): $app_url"

ds_curl_serve "$app_url" "$app_deb"
size=$(stat -c %s "$app_deb")
lock_set desktop_packages.example-app.size "$((size + 1))"
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "size mismatch: "
assert_contains "$DS_STDERR" "/example-app_1.2.3.deb (expected $((size + 1)) bytes, got $size)"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "" "$(temp_dirs)"

lock_set desktop_packages.example-app.size "$size"
lock_set desktop_packages.example-app.sha256 "\"$(printf '0%.0s' {1..64})\""
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "SHA-256 mismatch: "
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "" "$(temp_dirs)"

# The Package field must be one of packageNames, the Architecture field
# must match when declared.
pin_download desktop_packages.example-app "$term_deb" "$app_url" 1.2.3
expect_refusal "example-app (deb): unexpected package example-term in $app_url (expected example-app)"
pin_download desktop_packages.example-app "$app_deb" "$app_url" 1.2.3
arm_deb=$DS_TEST_ROOT/example-term_0.9.0_arm64.deb
ds_fake_deb "$arm_deb" example-term 0.9.0 arm64
pin_download desktop_packages.example-term "$arm_deb" "$term_url" 0.9.0
expect_refusal "example-term (deb): unexpected architecture arm64 in $term_url (expected amd64)"
pin_download desktop_packages.example-term "$term_deb" "$term_url" 0.9.0

# An alias is accepted for the download and for the floor.
alias_deb=$DS_TEST_ROOT/example-app-classic_1.2.3_amd64.deb
ds_fake_deb "$alias_deb" example-app-classic 1.2.3
pin_download desktop_packages.example-app "$alias_deb" "$app_url" 1.2.3
manifest_edit '(.components[] | select(.name == "example-app") | .install.packageNames) = ["example-app", "example-app-classic"]'
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "1.2.3" "$(ds_dpkg_version example-app-classic)"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-app-classic 1.2.3"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "0" "$(ds_call_count curl)"
rm -rf "${DS_STUB_STATE:?}/dpkg/installed" "$DS_TEST_ROOT/hook-ran"
manifest_edit '(.components[] | select(.name == "example-app") | .install.packageNames) = ["example-app"]'
pin_download desktop_packages.example-app "$app_deb" "$app_url" 1.2.3

# A failed apt-get update stops the transaction before apt-get install; a
# failed apt-get install stops the phase before the verification and the
# hooks. Both hold when the engine runs in a `||` context, where bash
# suppresses errexit.
ds_stub_route apt-get 'update*' --exit 100
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: apt-get update failed; nothing was installed" "${DS_STDERR##*$'\n'}"
assert_eq "1" "$(ds_call_count sudo)"
assert_not_contains "$(ds_calls_of apt-get)" "install"
assert_eq "" "$(ds_dpkg_version example-app)$(ds_dpkg_version example-term)"
[[ ! -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "a hook ran after a failed apt-get update"
assert_eq "" "$(temp_dirs)"
ds_stub_clear_routes apt-get
ds_stub_route apt-get 'install*' --exit 100
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: apt-get install failed" "${DS_STDERR##*$'\n'}"
assert_eq "2" "$(ds_call_count sudo)"
assert_eq "" "$(ds_dpkg_version example-app)$(ds_dpkg_version example-term)"
[[ ! -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "a hook ran after a failed apt-get install"
assert_eq "" "$(temp_dirs)"
ds_stub_clear_routes apt-get

# The lock's floor is above what the transaction installed.
pin_download desktop_packages.example-app "$old_deb" "$app_url" 1.2.3
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: example-app (deb): example-app 1.2.3 or newer is not installed after the transaction (found 1.1.0)" "${DS_STDERR##*$'\n'}"
assert_eq "2" "$(ds_call_count sudo)"
[[ ! -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "a hook ran after a failed verification"
assert_eq "" "$(temp_dirs)"

# verifyAfterInstall = false accepts it.
manifest_edit '(.components[] | select(.name == "example-app") | .install.verifyAfterInstall) = false'
rm -rf "${DS_STUB_STATE:?}/dpkg/installed"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "1.1.0" "$(ds_dpkg_version example-app)"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-app 1.1.0 (not verified)"
[[ -e $DS_TEST_ROOT/hook-ran ]] || ds_fail "the post-install hook did not run"

# The temporary directory is removed on success too.
assert_eq "" "$(temp_dirs)"

