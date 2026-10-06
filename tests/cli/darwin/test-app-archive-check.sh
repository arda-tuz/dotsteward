# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # methods shell snippets are single-quoted on purpose
# The app-archive method's --check-only semantics (SPEC 3.4): the version is
# the CFBundleShortVersionString of <dest>/<appName>/Contents/Info.plist
# and must be at least the pin's minimum_version (a newer, self-updated
# bundle satisfies it); not-managed in adopt mode; configuration errors die
# with the component named. Through methods_check and `dotsteward install
# --check-only --json`.
# shellcheck source=tests/cli/darwin/helpers.sh
source "$DS_REPO_ROOT/tests/cli/darwin/helpers.sh"

app="Example App.app"
apps=$HOME/Applications
add_app example-app "$(jq -n --arg app "$app" '{ pin: "desktop_packages.example-app-darwin", appName: $app, dest: "~/Applications" }')"
lock_set desktop_packages.example-app-darwin \
  '{ "minimum_version": "1.2.3", "url": "https://downloads.example.invalid/example-app/1.2.3/darwin-arm64/stable", "size": 1, "sha256": "00" }'

check() {
  in_methods_shell 'status=0; methods_check example-app "$1" || status=$?; printf "%s|%s|%s\n" "$status" "$METHODS_STATUS" "$METHODS_DETAIL"' "$1"
}

# Missing bundle: failed.
assert_eq "1|failed|$app 1.2.3 or newer is not installed in ~/Applications (found none)" "$(check fresh)"
# Adopt mode: not managed, whatever is installed.
assert_eq "0|not-managed|system-level method in adopt mode" "$(check workstation)"

# The pinned version, a newer one and an older one.
make_bundle "$apps" "$app" 1.2.3
assert_eq "0|satisfied|$app 1.2.3" "$(check fresh)"
rm -rf -- "${apps:?}/$app"
make_bundle "$apps" "$app" 1.10.0 binary
assert_eq "0|satisfied|$app 1.10.0" "$(check fresh)"
rm -rf -- "${apps:?}/$app"
make_bundle "$apps" "$app" 1.2.2
assert_eq "1|failed|$app 1.2.3 or newer is not installed in ~/Applications (found 1.2.2)" "$(check fresh)"
# A pre-release sorts before its release.
rm -rf -- "${apps:?}/$app"
make_bundle "$apps" "$app" 1.2.3-insider
assert_eq "1|failed|$app 1.2.3 or newer is not installed in ~/Applications (found 1.2.3-insider)" "$(check fresh)"
# A bundle without a readable version is not the pinned application.
rm -rf -- "${apps:?}/$app"
make_bundle "$apps" "$app" 1.2.3 none
assert_eq "1|failed|$app 1.2.3 or newer is not installed in ~/Applications (found no version)" "$(check fresh)"

# The lock entry may hold version instead of minimum_version.
rm -rf -- "${apps:?}/$app"
make_bundle "$apps" "$app" 2.0.0
lock_set desktop_packages.example-app-darwin \
  '{ "version": "2.0.0", "url": "https://downloads.example.invalid/x", "size": 1, "sha256": "00" }'
assert_eq "0|satisfied|$app 2.0.0" "$(check fresh)"

# dest defaults to ~/Applications; an absolute dest is used as it is.
jq '(.components[] | select(.name == "example-app") | .install) |= del(.dest)' "$darwin_manifest" >"$DS_TEST_ROOT/m.json"
mv "$DS_TEST_ROOT/m.json" "$darwin_manifest"
assert_eq "0|satisfied|$app 2.0.0" "$(check fresh)"
mkdir -p "$DS_TEST_ROOT/system-apps"
make_bundle "$DS_TEST_ROOT/system-apps" "$app" 2.1.0
jq --arg dest "$DS_TEST_ROOT/system-apps" '(.components[] | select(.name == "example-app") | .install.dest) = $dest' \
  "$darwin_manifest" >"$DS_TEST_ROOT/m.json"
mv "$DS_TEST_ROOT/m.json" "$darwin_manifest"
assert_eq "0|satisfied|$app 2.1.0" "$(check fresh)"

# Through the install command: --check-only reports every component.
assert_exit 0 run_install --profile fresh --check-only --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/report.json"
assert_json "$DS_TEST_ROOT/report.json" \
  '.result == "passed" and .check_only and .components == [{ name: "example-app", method: "app-archive", status: "satisfied", detail: "Example App.app 2.1.0" }]'
assert_exit 0 run_install --profile workstation --check-only
assert_contains "$DS_STDOUT" "[dotsteward] example-app (app-archive): not-managed: system-level method in adopt mode"
rm -rf -- "$DS_TEST_ROOT/system-apps/$app"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: example-app (app-archive): $app 2.0.0 or newer is not installed in $DS_TEST_ROOT/system-apps (found none)"
# Nothing was installed or downloaded by a check.
assert_eq 0 "$(ds_call_count curl)"
[[ ! -e $DS_TEST_ROOT/system-apps/$app ]] || ds_fail "a check installed the bundle"

# Configuration errors name the component.
bad_block() {
  jq --argjson install "$1" '(.components[] | select(.name == "example-app") | .install) = $install' \
    "$darwin_manifest" >"$DS_TEST_ROOT/m.json"
  mv "$DS_TEST_ROOT/m.json" "$darwin_manifest"
  assert_exit 1 check fresh
}
bad_block '{ "appName": "Example App.app" }'
assert_eq "[dotsteward] ERROR: example-app (app-archive): the install block needs pin and appName" "$DS_STDERR"
bad_block '{ "pin": "desktop_packages.example-app-darwin" }'
assert_eq "[dotsteward] ERROR: example-app (app-archive): the install block needs pin and appName" "$DS_STDERR"
for name in "Example App" "Apps/Example.app" ".app" "../Example.app" ".Example.app"; do
  bad_block "$(jq -n --arg app "$name" '{ pin: "desktop_packages.example-app-darwin", appName: $app }')"
  assert_eq "[dotsteward] ERROR: example-app (app-archive): invalid appName: $name (a bundle name ending in .app)" "$DS_STDERR"
done
bad_block '{ "pin": "desktop_packages.example-app-darwin", "appName": "Example App.app", "dest": "Applications" }'
assert_eq "[dotsteward] ERROR: example-app (app-archive): dest must be ~/... or absolute: Applications" "$DS_STDERR"
bad_block '{ "pin": "desktop_packages.missing", "appName": "Example App.app" }'
assert_eq "[dotsteward] ERROR: versions.lock.json lacks desktop_packages.missing (required by component example-app)" "$DS_STDERR"
lock_set desktop_packages.example-app-darwin '{ "url": "https://downloads.example.invalid/x" }'
bad_block '{ "pin": "desktop_packages.example-app-darwin", "appName": "Example App.app" }'
assert_eq "[dotsteward] ERROR: example-app (app-archive): versions.lock.json desktop_packages.example-app-darwin lacks minimum_version (or version)" "$DS_STDERR"

# Called without the methods engine, the platform functions refuse.
assert_exit 1 in_darwin_lib 'platform_app_archive_check example-app'
assert_eq "[dotsteward] ERROR: platform_app_archive_check: cli/lib/methods.sh is not loaded" "$DS_STDERR"
assert_exit 1 in_darwin_lib 'platform_app_archive_install example-app'
assert_eq "[dotsteward] ERROR: platform_app_archive_install: cli/lib/methods.sh is not loaded" "$DS_STDERR"
