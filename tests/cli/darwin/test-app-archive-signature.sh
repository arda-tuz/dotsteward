# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # methods shell snippets are single-quoted on purpose
# The app-archive method verifies the sigstore signature the lock records
# for its pin (offline, with the real cosign and the trusted root of the
# lock) after the download and before the archive is opened: a signature of
# another file stops the install and leaves the bundle alone; the archive
# the signature covers is installed. A pin without a recorded signature is
# installed and reported as unsigned.
# shellcheck source=tests/cli/darwin/helpers.sh
source "$DS_REPO_ROOT/tests/cli/darwin/helpers.sh"

command -v cosign >/dev/null || ds_fail "cosign is required by this test"
ds_use_stubs curl
darwin_use_tools ditto
fixtures=$(ds_fixture common/sigstore)
app="Example App.app"
bundle=$HOME/Applications/$app
url=https://downloads.example.invalid/example-app/1.2.3/darwin-arm64/stable
add_app example-app "$(jq -n --arg app "$app" '{ pin: "desktop_packages.example-app-darwin", appName: $app, dest: "~/Applications" }')"
make_bundle "$DS_TEST_ROOT/release-1.2.3" "$app" 1.2.3
make_zip "$DS_TEST_ROOT/example-1.2.3.zip" "$DS_TEST_ROOT/release-1.2.3"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 1.2.3

install_app() {
  in_methods_shell 'platform_app_archive_install example-app; printf "%s|%s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}

# Unsigned: installed, and said so.
assert_exit 0 install_app
assert_eq "installed|$app 1.2.3" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): $url is unsigned: versions.lock.json desktop_packages.example-app-darwin records no signature"
rm -rf -- "$bundle"

# A recorded signature of another file: refused before the archive is opened.
# The signature names release v4.1.0, so the pin is at that version.
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 4.1.0
lock_set trust "$(jq -c '{ sigstore_root: ., signers: { "desktop_packages.example-app-darwin": {
    kind: "sigstore", identity_regexp: "^https://github\\.com/example/example-release/\\.github/workflows/release\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$",
    issuer: "https://token.actions.githubusercontent.com", first_seen: "2026-11-01" } } }' "$fixtures/trusted_root.json")"
lock_set desktop_packages.example-app-darwin.signature "$(jq -c '{ kind: "message", subject: "asset",
    identity: "https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v4.1.0", bundle: . }' \
  "$fixtures/example-release-4.1.0.sigstore.json")"
: >"$DS_CALL_LOG"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "[dotsteward] ERROR: example-app (app-archive): the sigstore signature of stable does not verify: "
assert_eq "0" "$(ds_call_count ditto)"
[[ ! -e $bundle ]] || ds_fail "the bundle was installed from an archive its signature does not cover"
assert_eq "" "$(temp_dirs)"

# The archive the signature covers (the release blob stands in for a zip
# the test cannot sign at run time): verified, then opened.
pin_archive desktop_packages.example-app-darwin "$fixtures/example-release-4.1.0" "$url" 4.1.0
lock_set desktop_packages.example-app-darwin.signature "$(jq -c '{ kind: "message", subject: "asset",
    identity: "https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v4.1.0", bundle: . }' \
  "$fixtures/example-release-4.1.0.sigstore.json")"
assert_exit 1 install_app
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): sigstore signature of stable verified: https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v4.1.0"
assert_contains "$DS_STDERR" "unsupported archive format"
