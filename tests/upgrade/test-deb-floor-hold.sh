# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# A deb package the owner holds (apt-mark hold: dpkg status "hold ok installed") is installed,
# as the install sees it: its floor moves once the held version is the one upstream calls the
# latest, and the review never says it is not installed.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

jq '(.components[] | select(.name == "example-app")).install.pin = "desktop_packages.example-app"' "$mirror" >"$mirror.new"
mv -- "$mirror.new" "$mirror"
git -C "$up_inst" commit -q -am "chore: the floor of example-app"
git -C "$up_inst" push -q origin HEAD:main
move desktop_packages.example-app 2.0-1 download
printf '{"items": [{"id": "desktop_packages.example-app", "latest": "2.0-1", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"

ds_dpkg_installed example-tracked 2.0-1
sed -i 's/^Status: .*/Status: hold ok installed/' "$DS_STUB_STATE/dpkg/installed/example-tracked"
assert_exit 3 upgrade --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip desktop_packages.example-app"
assert_eq 2.0-1 "$(jq -r '."desktop_packages.example-app" // "none"' "$up_inst/versions.lock.json")"
review_json '[.items[] | select(.code == "deb-floors-wait")] | length == 0'
