# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_*, vscode_* and methods_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs in single quotes
# The vscode deb install block, as the manifest renders it, driven through
# `dotsteward install` (cli/lib/methods.sh) with the curl stub serving a
# stand-in DEB at the seed's official URL. In fresh mode a missing or older
# code package is downloaded, its Package (code) and Architecture (amd64)
# are asserted, and one apt transaction installs it; the vendor's own
# package revision (1.140.0-<build>) satisfies the floor, and a newer
# version the application updated itself through its repository is kept
# without a download. The installer never answers the package's repository
# question, never downgrades and never asks for -y. In adopt mode VS Code is
# not managed.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

# The manifest entry before the methods helpers change the working state.
entry=$(vscode_json 'entryOf (vscode { }) "x86_64-linux"')
pin=$(jq '.versions_lock.desktop_packages.vscode' "$vscode_component/seed.json")
floor=$(jq -r '.minimum_version' <<<"$pin")
url=$(jq -r '.url' <<<"$pin")
[[ $url == https://update.code.visualstudio.com/* ]] || ds_fail "unexpected seed URL: $url"

# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl

# serve_deb VERSION [ARCH]: a stand-in code DEB at the seed's URL, pinned in
# the instance lock with the seed's floor and the stand-in's size and digest.
serve_deb() {
  local deb=$DS_TEST_ROOT/code_$1_${2:-amd64}.deb
  ds_fake_deb "$deb" code "$1" "${2:-amd64}"
  ds_curl_serve "$url" "$deb"
  lock_set desktop_packages.vscode "$(jq --argjson size "$(stat -c %s -- "$deb")" \
    --arg sha "$(sha256sum -- "$deb" | awk '{print $1}')" '.size = $size | .sha256 = $sha' <<<"$pin")"
}

add_component vscode deb "$(jq -c '.install' <<<"$entry")"
manifest_edit '(.components[] | select(.name == "vscode")) |= (.platforms = $e.platforms
  | .supported_methods = $e.supported_methods | .options = $e.options)' --argjson e "$entry"

# Nothing installed: --check-only fails on the floor.
serve_deb "$floor-1790759618"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "vscode (deb): code $floor or newer is not installed"

# Fresh mode: one verified HTTPS download from the official update service,
# the package asserted, one apt transaction without -y or downgrades.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$floor-1790759618" "$(ds_dpkg_version code)"
assert_eq "1" "$(ds_call_count curl)"
assert_contains "$(ds_calls_of curl)" "--proto =https --tlsv1.2 "
assert_contains "$(ds_calls_of curl)" "$url"
mapfile -t calls < <(ds_calls_of sudo)
assert_eq 2 "${#calls[@]}" "one apt-get update and one apt-get install"
assert_eq "sudo apt-get update" "${calls[0]}"
[[ ${calls[1]} == "sudo apt-get install --no-install-recommends $TMPDIR/dotsteward-install."*"/vscode_$floor.deb" ]] ||
  ds_fail "unexpected install call: ${calls[1]}"
assert_eq "0" "$(ds_call_count apt-get '*--allow-downgrades*')"
assert_eq "0" "$(ds_call_count apt-get '* -y *')"
assert_not_contains "$(<"$DS_CALL_LOG")" "debconf"
assert_contains "$DS_STDOUT" "[dotsteward] vscode (deb): installed: code $floor-1790759618"

# Installed: --check-only and a second run are satisfied without a download.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh --check-only
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "[dotsteward] vscode (deb): satisfied: code $floor-1790759618"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"

# A newer version (the application updated itself through its repository)
# is kept: no download, no downgrade.
ds_dpkg_installed code 9.0.0-1800000000
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "9.0.0-1800000000" "$(ds_dpkg_version code)"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"

# An older version is upgraded to the pin.
ds_dpkg_installed code 1.0.0-1700000000
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$floor-1790759618" "$(ds_dpkg_version code)"
assert_eq "1" "$(ds_call_count curl)"

# A DEB of another architecture is refused before any apt call.
ds_dpkg_installed code 1.0.0-1700000000
serve_deb "$floor-1790759618" arm64
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "vscode (deb): unexpected architecture arm64 in $url (expected amd64)"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "1.0.0-1700000000" "$(ds_dpkg_version code)"

# Adopt mode: VS Code is not managed, whatever is installed.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation --check-only
assert_contains "$DS_STDOUT$DS_STDERR" "vscode (deb): not-managed: system-level method in adopt mode"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"
