# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The floor of a deb package is checked against the names of install.packageNames, which are
# aliases of one package: like the install, which verifies the floor with the first installed
# name at or above it, the floor moves once any of its names has the version, never waiting for
# an alias that is not installed. A deb pin without package names cannot be checked at all (the
# evaluation refuses such a component; a mirror can still have one): its floor stays where it
# is, and the review says why and what to add, instead of waiting for dpkg forever.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

floor() {
  jq -r '."desktop_packages.example-app" // "none"' "$up_inst/versions.lock.json"
}
# names JSON: the package names of example-app in the mirror, with its floor pin.
names() {
  jq --argjson names "$1" '(.components[] | select(.name == "example-app")).install
    |= (.pin = "desktop_packages.example-app" | .packageNames = $names)' "$mirror" >"$mirror.new"
  mv -- "$mirror.new" "$mirror"
  git -C "$up_inst" commit -q -am "chore: the package names of example-app"
  git -C "$up_inst" push -q origin HEAD:main
}

move desktop_packages.example-app 2.0-1 download
printf '{"items": [{"id": "desktop_packages.example-app", "latest": "2.0-1", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"

# Two names of one package, the newer one installed at the version: the floor moves.
names '["example-tracked", "example-tracked-old"]'
ds_dpkg_installed example-tracked 2.0-1
assert_exit 3 upgrade --tracked
assert_not_contains "$(steps '^pins .*apply')" "--skip desktop_packages.example-app"
assert_eq 2.0-1 "$(floor)"
review_json '[.items[] | select(.code == "deb-floors-wait")] | length == 0'

# No package names: nothing says what dpkg has, so the floor stays, and the review names the
# component and what it lacks.
git -C "$up_inst" reset -q --hard "$(remote_oid)"
jq 'del(."desktop_packages.example-app")' "$up_inst/versions.lock.json" >"$up_inst/versions.lock.json.new"
mv -- "$up_inst/versions.lock.json.new" "$up_inst/versions.lock.json"
git -C "$up_inst" commit -q -am "chore: the floor of example-app back"
git -C "$up_inst" push -q origin HEAD:main
names '[]'
clear_log
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^pins .*apply')" "--skip desktop_packages.example-app"
assert_eq none "$(floor)"
review_json '[.items[] | select(.code == "deb-floors-wait")] | length == 0'
review_json '[.items[] | select(.code == "deb-floor-unknown") | .ids] == [["desktop_packages.example-app"]]'
review_json '[.items[] | select(.code == "deb-floor-unknown") | .message][0]
  | contains("example-app names no install.packageNames")'
