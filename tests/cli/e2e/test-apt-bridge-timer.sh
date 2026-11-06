# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# A machine that took in a github-release deb component with an older
# framework has the bridge's source and repository but no timer, with or
# without the APT hook of that framework. The shared E2E hook (run through
# `dotsteward e2e` of an adopt-mode profile, as a real instance runs it)
# reports the step that is left and stays green; only the check of a named
# component (`install --component NAME --check-only`), which the machine's
# owner runs when the step is done, holds the machine to the timer. Nothing of
# this changes the machine.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

ds_use_stubs sudo dpkg dpkg-query dpkg-deb apt-cache systemctl curl

add_component example-app deb '{
  "pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": "amd64",
  "verifyAfterInstall": true, "apt": [], "aptSources": [],
  "githubRelease": {
    "repository": "example-org/example-app",
    "assets": {"amd64": "example-app-{version}-linux-x86_64.deb"},
    "checksums": "SHA256SUMS.txt"
  }
}'
lock_set desktop_packages.example-app "$(jq -n '{minimum_version: "1.2.0",
  url: "https://downloads.example.invalid/example-app-1.2.0.deb", size: 1, sha256: ("0" * 64)}')"
add_e2e_hook example-app package main null true <"$DS_REPO_ROOT/modules/core/github-release-deb-e2e.sh"
publish_instance

# The machine as the older framework left it, without its hook file: the
# package and its desktop entry, the CLI, the source APT reads and the
# repository it serves; no timer.
ds_dpkg_installed example-app 1.3.0-1 amd64 "Files=/usr/bin/example-app /usr/share/applications/example-app.desktop"
ds_dpkg_installed curl 8.5.0
mkdir -p "$DS_SYSTEM_ROOT/usr/share/applications"
: >"$DS_SYSTEM_ROOT/usr/share/applications/example-app.desktop"
printf '#!%s\necho "example-app 1.3.0"\n' "$BASH" >"$DS_TEST_ROOT/bin/example-app-cli"
chmod 0755 "$DS_TEST_ROOT/bin/example-app-cli"
ds_stub_route apt-cache 'policy example-app' --stdout "example-app:
  Installed: 1.3.0-1
  Candidate: 1.3.0-1
  Version table:
 *** 1.3.0-1 500
        500 file:/var/lib/dotsteward/apt-bridge ./ Packages
        100 /var/lib/dpkg/status"
source_file=$DOTSTEWARD_APT_DIR/sources.list.d/dotsteward-apt-bridge.sources
hook=$DOTSTEWARD_APT_DIR/apt.conf.d/60dotsteward-apt-bridge
units=$DS_SYSTEM_ROOT/etc/systemd/system
timer=$units/dotsteward-apt-bridge.timer
repo=$DS_SYSTEM_ROOT/var/lib/dotsteward/apt-bridge
printf '%s\n' "Types: deb" "URIs: file:$repo" "Suites: ./" "Trusted: yes" >"$source_file"
mkdir -p "$repo" "$DOTSTEWARD_APT_DIR/apt.conf.d"
printf 'Origin: dotsteward\n' >"$repo/Release"
: >"$repo/Packages"
before=$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)
pending="example-app: bridge timer not installed: run dotsteward install --profile workstation --component example-app"
success="example-app 1.3.0-1: floor 1.2.0, desktop entry, CLI and the local APT bridge"

# `dotsteward e2e` reports the step and stays green, also with its report as
# a JSON document, and it does not touch the machine.
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT$DS_STDERR" "$pending"
assert_contains "$DS_STDOUT$DS_STDERR" "$success"
assert_exit 0 run_e2e --json
assert_contains "$DS_STDERR" "$pending"
assert_json - '.result == "passed" and .findings == []' <<<"$DS_STDOUT"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count systemctl)"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "$before" "$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)"

# So does a machine whose hook still runs: it has not taken in the timer.
printf '// Written by dotsteward: refreshes the local APT bridge before every update.\n' >"$hook"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT$DS_STDERR" "$pending"
rm -f -- "$hook"

# The profile check does not manage the deb method in adopt mode; a named
# component is checked by its method, which is where the timer is enforced.
run_check() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" install --profile workstation --check-only "$@" </dev/null
}
assert_exit 0 run_check
assert_contains "$DS_STDOUT" "example-app (deb): not-managed: system-level method in adopt mode"
assert_exit 1 run_check --component example-app
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file"

# A timer file alone is not enough, and an enabled one ends the report.
mkdir -p "$units"
printf '[Timer]\nOnCalendar=daily\n\n[Install]\nWantedBy=timers.target\n' >"$timer"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT$DS_STDERR" "$pending"
assert_exit 0 sudo systemctl enable dotsteward-apt-bridge.timer
assert_exit 0 run_e2e
assert_not_contains "$DS_STDOUT$DS_STDERR" "bridge timer not installed"
assert_contains "$DS_STDOUT$DS_STDERR" "$success"

# A hook that came back next to the timer is reported too, and stays green:
# the same step removes it.
printf '// Written by dotsteward: refreshes the local APT bridge before every update.\n' >"$hook"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT$DS_STDERR" "example-app: obsolete bridge hook $hook: run dotsteward install --profile workstation --component example-app"
