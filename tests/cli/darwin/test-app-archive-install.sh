# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # methods shell snippets are single-quoted on purpose
# The app-archive method's fresh-mode install from a zip (SPEC 3.4), through
# platform_app_archive_install and `dotsteward install --profile fresh`: the
# pinned archive is downloaded over HTTPS and verified by size and SHA-256,
# extracted with ditto into a temporary directory, its bundle checked
# (present at the archive root, Info.plist version at least the pin) before
# anything is replaced, an existing older bundle moved into a private backup
# first, the new bundle copied into place with ditto (symlinks and modes
# kept) and its version read again. A bundle at or above the pin is kept; a
# symlink or a file at the destination, a non-HTTPS URL, a failed download,
# a wrong digest, an archive without the bundle or with an older one are
# refused before any change, and a failed copy restores the previous bundle.
# Temporary directories never outlive the call.
# shellcheck source=tests/cli/darwin/helpers.sh
source "$DS_REPO_ROOT/tests/cli/darwin/helpers.sh"

ds_use_stubs curl
darwin_use_tools ditto
app="Example App.app"
apps=$HOME/Applications
bundle=$apps/$app
url=https://downloads.example.invalid/example-app/1.2.3/darwin-arm64/stable
add_app example-app "$(jq -n --arg app "$app" '{ pin: "desktop_packages.example-app-darwin", appName: $app, dest: "~/Applications" }')"

# The vendor archive: the bundle at the zip's root.
make_bundle "$DS_TEST_ROOT/release-1.2.3" "$app" 1.2.3
make_zip "$DS_TEST_ROOT/example-1.2.3.zip" "$DS_TEST_ROOT/release-1.2.3"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 1.2.3

install_app() {
  in_methods_shell 'platform_app_archive_install example-app; printf "%s|%s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}

# --- Fresh install --------------------------------------------------------
assert_exit 0 install_app
assert_eq "installed|$app 1.2.3" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): downloading $url"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): installed $bundle"
[[ -d $bundle && ! -L $bundle ]] || ds_fail "the bundle is not installed"
[[ -x $bundle/Contents/MacOS/app ]] || ds_fail "the executable lost its mode"
assert_symlink_to "$bundle/Contents/Frameworks/Example.framework/Versions/Current" A
[[ $(ds_calls_of curl) == "curl --proto =https --tlsv1.2 --fail --location "*" $url" ]] ||
  ds_fail "unexpected download: $(ds_calls_of curl)"
# Extracted into a temporary directory, then copied into place.
[[ $(ds_calls_of ditto | sed -n 1p) == "ditto -x -k $TMPDIR/dotsteward-app-archive."*"/stable $TMPDIR/dotsteward-app-archive."*"/extracted" ]] ||
  ds_fail "unexpected extraction: $(ds_calls_of ditto)"
[[ $(ds_calls_of ditto | sed -n 2p) == "ditto $TMPDIR/dotsteward-app-archive."*"/extracted/$(printf %q "$app") $(printf %q "$bundle")" ]] ||
  ds_fail "unexpected copy: $(ds_calls_of ditto)"
assert_eq 2 "$(ds_call_count ditto)"
assert_eq "" "$(temp_dirs)"
# No backup: there was no bundle.
[[ ! -d $DOTSTEWARD_STATE_ROOT/backups ]] || ds_fail "a backup was made without a previous bundle"

# --- At or above the pin: kept, nothing downloaded ----------------------------
: >"$DS_CALL_LOG"
assert_exit 0 install_app
assert_eq "satisfied|$app 1.2.3" "$DS_STDOUT"
assert_calls
rm -rf -- "$bundle"
make_bundle "$apps" "$app" 1.3.0
assert_exit 0 install_app
assert_eq "satisfied|$app 1.3.0" "$DS_STDOUT"
assert_calls

# --- Older bundle: backed up, then replaced -----------------------------------
rm -rf -- "$bundle"
make_bundle "$apps" "$app" 1.0.0
printf 'user data\n' >"$bundle/Contents/marker"
assert_exit 0 install_app
assert_eq "installed|$app 1.2.3" "$(tail -n 1 <<<"$DS_STDOUT")"
mapfile -t backups < <(find "$DOTSTEWARD_STATE_ROOT/backups" -mindepth 1 -maxdepth 1 -type d)
assert_eq 1 "${#backups[@]}"
backup=${backups[0]}/files$bundle
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): previous $bundle moved to $backup"
[[ ${backups[0]##*/} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || ds_fail "backup directory is not a UTC timestamp: ${backups[0]}"
assert_file_mode "${backups[0]}" 700
assert_eq "user data" "$(<"$backup/Contents/marker")"
[[ ! -e $bundle/Contents/marker ]] || ds_fail "the new bundle kept a file of the old one"
assert_eq 1.2.3 "$(in_darwin_lib 'app_bundle_version "$1"' "$bundle")"
assert_eq "" "$(temp_dirs)"

# --- Refusals before any change -----------------------------------------------
# Each case starts from an older bundle that must stay untouched.
reset_old() {
  rm -rf -- "$bundle" "$DOTSTEWARD_STATE_ROOT/backups"
  make_bundle "$apps" "$app" 1.0.0
  : >"$DS_CALL_LOG"
}
assert_untouched() {
  assert_eq 1.0.0 "$(in_darwin_lib 'app_bundle_version "$1"' "$bundle")" "$1"
  [[ ! -d $DOTSTEWARD_STATE_ROOT/backups ]] || ds_fail "$1: a backup was made"
  assert_eq "" "$(temp_dirs)" "$1: temporary directories"
}

# A symlink or a file at the destination.
rm -rf -- "$bundle"
mkdir -p "$DS_TEST_ROOT/elsewhere/$app"
ln -s "$DS_TEST_ROOT/elsewhere/$app" "$bundle"
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): refusing to replace a symlink or non-directory: $bundle" "$DS_STDERR"
[[ -L $bundle ]] || ds_fail "the symlink was replaced"
rm -f -- "$bundle"
printf 'file\n' >"$bundle"
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): refusing to replace a symlink or non-directory: $bundle" "$DS_STDERR"
rm -f -- "$bundle"

# A non-HTTPS URL.
reset_old
lock_set desktop_packages.example-app-darwin.url '"http://downloads.example.invalid/x.zip"'
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): refusing a non-HTTPS download URL: http://downloads.example.invalid/x.zip" "$DS_STDERR"
assert_untouched "non-HTTPS"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 1.2.3

# A failed download, a wrong size, a wrong digest.
reset_old
ds_curl_fail "$url" 6 "Could not resolve host: downloads.example.invalid"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "[dotsteward] ERROR: example-app (app-archive): download failed (curl exit 6): $url"
assert_untouched "download failure"
ds_curl_serve "$url" "$DS_TEST_ROOT/example-1.2.3.zip"
reset_old
lock_set desktop_packages.example-app-darwin.size 12
assert_exit 1 install_app
assert_contains "$DS_STDERR" "size mismatch"
assert_untouched "size mismatch"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 1.2.3
reset_old
lock_set desktop_packages.example-app-darwin.sha256 "\"$(printf '0%.0s' {1..64})\""
assert_exit 1 install_app
assert_contains "$DS_STDERR" "SHA-256 mismatch"
assert_untouched "digest mismatch"
assert_eq 0 "$(ds_call_count ditto)"

# Not a zip or a disk image.
reset_old
printf 'plain text, not an archive\n' >"$DS_TEST_ROOT/not-an-archive"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/not-an-archive" "$url" 1.2.3
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): unsupported archive format (expected a zip or a disk image): $url" "$DS_STDERR"
assert_untouched "unsupported format"

# A zip ditto cannot extract.
reset_old
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 1.2.3
darwin_tool_set ditto fail extract
assert_exit 1 install_app
assert_contains "$DS_STDERR" "[dotsteward] ERROR: example-app (app-archive): cannot extract the archive (ditto exit 1): $url"
assert_untouched "extraction failure"
darwin_tool_set ditto fail ''

# The bundle is not at the archive's root.
reset_old
mkdir -p "$DS_TEST_ROOT/nested/folder"
make_bundle "$DS_TEST_ROOT/nested/folder" "$app" 1.2.3
make_zip "$DS_TEST_ROOT/nested.zip" "$DS_TEST_ROOT/nested"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/nested.zip" "$url" 1.2.3
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): the archive has no bundle $app at its root: $url" "$DS_STDERR"
assert_untouched "bundle not at the root"

# The bundle has no readable version, or an older one than the pin.
reset_old
make_bundle "$DS_TEST_ROOT/no-version" "$app" 1.2.3 none
make_zip "$DS_TEST_ROOT/no-version.zip" "$DS_TEST_ROOT/no-version"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/no-version.zip" "$url" 1.2.3
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): $app in $url has no readable CFBundleShortVersionString" "$DS_STDERR"
assert_untouched "no version"
reset_old
make_bundle "$DS_TEST_ROOT/release-1.2.0" "$app" 1.2.0
make_zip "$DS_TEST_ROOT/example-1.2.0.zip" "$DS_TEST_ROOT/release-1.2.0"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.0.zip" "$url" 1.2.3
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): $url holds $app 1.2.0, older than 1.2.3; nothing was replaced" "$DS_STDERR"
assert_untouched "older archive"

# --- A failed copy restores the previous bundle ---------------------------------
reset_old
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-1.2.3.zip" "$url" 1.2.3
darwin_tool_set ditto fail copy
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): cannot copy the bundle to $bundle (ditto exit 1); the previous bundle was restored" \
  "$(grep -F 'ERROR' <<<"$DS_STDERR")"
assert_eq 1.0.0 "$(in_darwin_lib 'app_bundle_version "$1"' "$bundle")"
assert_eq "" "$(find "$DOTSTEWARD_STATE_ROOT/backups" -name "$app" -print)" "the backup was moved back"
assert_eq "" "$(temp_dirs)"
darwin_tool_set ditto fail ''

# Without a previous bundle a failed copy leaves nothing behind.
rm -rf -- "$bundle" "$DOTSTEWARD_STATE_ROOT/backups"
darwin_tool_set ditto fail copy
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): cannot copy the bundle to $bundle (ditto exit 1)" \
  "$(grep -F 'ERROR' <<<"$DS_STDERR")"
[[ ! -e $bundle ]] || ds_fail "a partial bundle was left in place"
darwin_tool_set ditto fail ''

# --- Through the install command (fresh mode) -----------------------------------
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/report.json"
assert_json "$DS_TEST_ROOT/report.json" \
  '.result == "passed" and .mode == "fresh" and .components == [{ name: "example-app", method: "app-archive", status: "installed", detail: "Example App.app 1.2.3" }]'
assert_eq "preflight --read-only --json --profile fresh" "$(ds_calls_of preflight)"
assert_contains "$DS_STDERR" "[dotsteward] system install verified for profile fresh"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): satisfied: $app 1.2.3"
# Adopt mode: one line, nothing installed.
rm -rf -- "$bundle"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation
assert_eq "[dotsteward] workstation (adopt mode): system install skipped; not managed: example-app" "$DS_STDOUT"
assert_calls
[[ ! -e $bundle ]] || ds_fail "adopt mode installed the bundle"
assert_eq "" "$(temp_dirs)"
