# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # methods shell snippets are single-quoted on purpose
# The app-archive method with a disk image (SPEC 3.4: "verified zip or
# dmg"): the format is recognised by content (the UDIF trailer), not by the
# URL; the image is attached read-only without Finder and without opening
# it, at a mount point inside the temporary directory, the bundle copied out
# with ditto, and the image always detached again: after a successful copy,
# when the bundle is missing, and when the first detach fails (then with
# -force). An image hdiutil cannot attach is refused before any change.
# shellcheck source=tests/cli/darwin/helpers.sh
source "$DS_REPO_ROOT/tests/cli/darwin/helpers.sh"

ds_use_stubs curl
darwin_use_tools ditto hdiutil
app="Example App.app"
bundle=$HOME/Applications/$app
url=https://downloads.example.invalid/example-app/2.0.0/darwin-universal/stable
add_app example-app "$(jq -n --arg app "$app" '{ pin: "desktop_packages.example-app-darwin", appName: $app }')"

install_app() {
  in_methods_shell 'platform_app_archive_install example-app; printf "%s|%s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
mounted() {
  cat "$DS_STUB_STATE/hdiutil/mounted" 2>/dev/null || true
}

make_bundle "$DS_TEST_ROOT/volume" "$app" 2.0.0
ln -s /Applications "$DS_TEST_ROOT/volume/Applications"
make_dmg "$DS_TEST_ROOT/example-2.0.0.dmg" "$DS_TEST_ROOT/volume"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-2.0.0.dmg" "$url" 2.0.0

# --- Install ------------------------------------------------------------------
assert_exit 0 install_app
assert_eq "installed|$app 2.0.0" "$(tail -n 1 <<<"$DS_STDOUT")"
mapfile -t calls < <(ds_calls_of hdiutil)
assert_eq 2 "${#calls[@]}"
[[ ${calls[0]} =~ ^hdiutil\ attach\ -nobrowse\ -readonly\ -noautoopen\ -mountpoint\ ([^ ]+)\ ([^ ]+)$ ]] ||
  ds_fail "unexpected attach: ${calls[0]}"
mount_point=${BASH_REMATCH[1]}
[[ $mount_point == "$TMPDIR/dotsteward-app-archive."*/mount ]] || ds_fail "mount point outside the temporary directory: $mount_point"
[[ ${BASH_REMATCH[2]} == "$TMPDIR/dotsteward-app-archive."*/stable ]] || ds_fail "attached another file: ${BASH_REMATCH[2]}"
assert_eq "hdiutil detach $mount_point" "${calls[1]}"
assert_eq "ditto $mount_point/$(printf %q "$app") ${mount_point%/mount}/extracted/$(printf %q "$app")" "$(ds_calls_of ditto | sed -n 1p)"
assert_eq "ditto ${mount_point%/mount}/extracted/$(printf %q "$app") $(printf %q "$bundle")" "$(ds_calls_of ditto | sed -n 2p)"
assert_eq "" "$(mounted)"
[[ -x $bundle/Contents/MacOS/app ]] || ds_fail "the bundle is not installed"
assert_symlink_to "$bundle/Contents/Frameworks/Example.framework/Versions/Current" A
[[ ! -e $HOME/Applications/Applications ]] || ds_fail "the volume's Applications link was copied"
assert_eq "" "$(temp_dirs)"

# --- The image is detached on every path -----------------------------------------
# The bundle is not on the volume.
rm -rf -- "$bundle" "$DS_TEST_ROOT/other-volume"
mkdir -p "$DS_TEST_ROOT/other-volume"
make_bundle "$DS_TEST_ROOT/other-volume" "Other.app" 2.0.0
make_dmg "$DS_TEST_ROOT/other.dmg" "$DS_TEST_ROOT/other-volume"
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/other.dmg" "$url" 2.0.0
: >"$DS_CALL_LOG"
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): the archive has no bundle $app at its root: $url" "$DS_STDERR"
assert_eq 1 "$(ds_call_count hdiutil 'detach *')"
assert_eq "" "$(mounted)"
assert_eq "" "$(temp_dirs)"
[[ ! -e $bundle ]] || ds_fail "a bundle was installed"

# The first detach fails (a busy volume): detached with -force.
pin_archive desktop_packages.example-app-darwin "$DS_TEST_ROOT/example-2.0.0.dmg" "$url" 2.0.0
darwin_tool_set hdiutil fail detach
: >"$DS_CALL_LOG"
assert_exit 0 install_app
assert_eq 1 "$(ds_call_count hdiutil 'detach -force *')"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: example-app (app-archive): detaching $TMPDIR/dotsteward-app-archive."
assert_eq "" "$(mounted)"
assert_eq "" "$(temp_dirs)"
darwin_tool_set hdiutil fail ''

# No detach succeeds: the command fails, and the still mounted temporary
# directory is left alone (never removed under a mounted volume).
rm -rf -- "$bundle"
darwin_tool_set hdiutil fail detach-all
: >"$DS_CALL_LOG"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "[dotsteward] ERROR: example-app (app-archive): cannot detach the disk image mounted at $TMPDIR/dotsteward-app-archive."
[[ ! -e $bundle ]] || ds_fail "a bundle was installed from an image that stayed attached"
left=$(mounted)
[[ $left == "$TMPDIR/dotsteward-app-archive."*/mount && -d $left ]] || ds_fail "unexpected mounts: $left"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: example-app (app-archive): the disk image is still attached at $left; detach it with 'hdiutil detach $left'"
darwin_tool_set hdiutil fail ''
hdiutil detach "$left" >/dev/null
rm -rf -- "${left%/mount}"
assert_eq "" "$(temp_dirs)"

# An image hdiutil cannot attach.
darwin_tool_set hdiutil fail attach
: >"$DS_CALL_LOG"
assert_exit 1 install_app
assert_eq "[dotsteward] ERROR: example-app (app-archive): cannot attach the disk image (hdiutil exit 1): $url" \
  "$(grep -F ERROR <<<"$DS_STDERR")"
assert_eq 0 "$(ds_call_count hdiutil 'detach *')"
assert_eq "" "$(temp_dirs)"
[[ ! -e $bundle ]] || ds_fail "a bundle was installed"
