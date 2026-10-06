# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# forbid_paths GLOB DIR...: each directory is checked on its own (a missing
# first directory never hides a match in the next one, the defect of the
# single find(1) call it replaces), case-insensitive name glob, regular
# files directly in the directory only. Prints every match and returns 1
# when there is one.
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

system_autostart=$DS_TEST_ROOT/etc/xdg/autostart
user_autostart=$HOME/.config/autostart
glob='*example*app*.desktop'

# Nothing anywhere, directories missing: no match.
assert_exit 0 forbid_paths "$glob" "$system_autostart" "$user_autostart"
assert_eq "" "$DS_STDOUT$DS_STDERR"

# The regression: the first directory is missing, the match is in the second.
mkdir -p "$user_autostart"
touch "$user_autostart/Example-App.desktop"
assert_exit 1 forbid_paths "$glob" "$system_autostart" "$user_autostart"
assert_eq "$user_autostart/Example-App.desktop" "$DS_STDOUT"

# Matches in several directories are all reported, in argument order.
mkdir -p "$system_autostart"
touch "$system_autostart/example_app.desktop" "$system_autostart/other.desktop"
assert_exit 1 forbid_paths "$glob" "$system_autostart" "$user_autostart"
assert_eq "$system_autostart/example_app.desktop"$'\n'"$user_autostart/Example-App.desktop" "$DS_STDOUT"

# Only regular files directly inside count; directories, deeper files and
# symlinks do not.
rm "$user_autostart/Example-App.desktop" "$system_autostart/example_app.desktop"
mkdir -p "$user_autostart/example-app.desktop" "$user_autostart/sub"
touch "$user_autostart/sub/example-app.desktop"
ln -s "$DS_TEST_ROOT/nowhere" "$user_autostart/link-example-app.desktop"
assert_exit 0 forbid_paths "$glob" "$system_autostart" "$user_autostart"
# A regular file given as a directory, or an unreadable directory, is not a
# match either.
touch "$DS_TEST_ROOT/plain-file"
assert_exit 0 forbid_paths "$glob" "$DS_TEST_ROOT/plain-file"

# Usage.
assert_exit 1 forbid_paths "$glob"
assert_eq "[dotsteward] ERROR: usage: forbid_paths GLOB DIR..." "$DS_STDERR"
