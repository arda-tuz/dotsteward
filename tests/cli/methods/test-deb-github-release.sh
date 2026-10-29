# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A deb component whose vendor publishes DEBs as GitHub release assets but
# runs no APT repository names them with install.githubRelease. The deb
# transaction then puts the local APT bridge on the machine before its one
# `apt-get update`: the bridge script, one configuration per package (the
# release download URL and the asset of the machine's architecture), an
# APT::Update::Pre-Invoke hook that runs the script, and a trusted flat
# file: source over the bridge repository; the system curl the script needs
# joins the transaction. Each file is written only when it differs, so a
# second run changes nothing. Later releases then arrive with plain
# `apt update && apt upgrade`. --check-only fails while a bridge file is
# missing or differs.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl
app_url=https://downloads.example.invalid/example-app_1.2.3_amd64.deb
pin_download desktop_packages.example-app "$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)" "$app_url" 1.2.3
ds_apt_available curl 8.5.0

add_component example-app deb '{
  "pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": "amd64",
  "verifyAfterInstall": true, "apt": [], "aptSources": [],
  "githubRelease": {
    "repository": "example-org/example-app",
    "assets": {"amd64": "example-app-{version}-linux-x86_64.deb", "arm64": "example-app-{version}-linux-aarch64.deb"},
    "checksums": "SHA256SUMS.txt"
  }
}'

apt_dir=$DOTSTEWARD_APT_DIR
script=$DS_SYSTEM_ROOT/usr/local/lib/dotsteward/apt-bridge.sh
conf=$DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d/example-app.conf
repo=$DS_SYSTEM_ROOT/var/lib/dotsteward/apt-bridge
hook=$apt_dir/apt.conf.d/60dotsteward-apt-bridge
source_file=$apt_dir/sources.list.d/dotsteward-apt-bridge.sources
assert_eq "$DS_SYSTEM_ROOT" "$DOTSTEWARD_SYSTEM_ROOT" "the harness points the system root at the fixture root"

expected_conf="package=example-app
architecture=amd64
url=https://github.com/example-org/example-app/releases/latest/download
asset=example-app-{version}-linux-x86_64.deb
checksums=SHA256SUMS.txt"
expected_hook="// Written by dotsteward: refreshes the local APT bridge before every update.
APT::Update::Pre-Invoke { \"if [ -f $script ]; then /bin/bash $script $DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d $repo || true; fi\"; };"
expected_source="Types: deb
URIs: file:$repo
Suites: ./
Trusted: yes"

# Before anything is installed, --check-only names the missing bridge.
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file $script is missing"

# Fresh install: the pinned DEB is downloaded first, then the bridge files,
# then one update and one install that also brings the system curl.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$(<"$DS_REPO_ROOT/cli/libexec/apt-bridge.sh")" "$(<"$script")"
assert_eq "$expected_conf" "$(<"$conf")"
assert_eq "$expected_hook" "$(<"$hook")"
assert_eq "$expected_source" "$(<"$source_file")"
for file in "$script" "$conf" "$hook" "$source_file"; do
  assert_file_mode "$file" 0644
done
assert_eq "1.2.3" "$(ds_dpkg_version example-app)"
assert_eq "8.5.0" "$(ds_dpkg_version curl)"
mapfile -t calls < <(grep -E '^(curl|sudo) ' "$DS_CALL_LOG")
assert_contains "${calls[0]}" " $app_url"
[[ ${calls[1]} == "sudo install -D -o root -g root -m 0644 $TMPDIR/dotsteward-install."*"/apt-bridge.sh $script" ]] ||
  ds_fail "unexpected script call: ${calls[1]}"
[[ ${calls[2]} == "sudo install -D -o root -g root -m 0644 "*" $conf" ]] || ds_fail "unexpected conf call: ${calls[2]}"
[[ ${calls[3]} == "sudo install -D -o root -g root -m 0644 "*" $hook" ]] || ds_fail "unexpected hook call: ${calls[3]}"
[[ ${calls[4]} == "sudo install -D -o root -g root -m 0644 "*" $source_file" ]] || ds_fail "unexpected source call: ${calls[4]}"
assert_eq "sudo timeout 600 apt-get update" "${calls[5]}"
[[ ${calls[6]} == "sudo apt-get install --no-install-recommends curl $TMPDIR/dotsteward-install."*"/example-app_1.2.3.deb" ]] ||
  ds_fail "unexpected install call: ${calls[6]}"
assert_eq 7 "${#calls[@]}" "one download, four files, one update, one install"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): apt bridge: example-org/example-app, example-app-{version}-linux-x86_64.deb"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-app 1.2.3, curl"
assert_eq "" "$(temp_dirs)"

# Everything current: no download, no sudo; --check-only passes.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"
assert_exit 0 run_install --profile fresh --check-only

# A bridge file that differs fails the check and is rewritten alone; the
# rewrite triggers the update, no package is installed.
printf 'changed\n' >>"$hook"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file $hook differs from the component"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$expected_hook" "$(<"$hook")"
assert_eq "1" "$(ds_call_count sudo 'install *')"
assert_eq "1" "$(ds_call_count sudo 'timeout 600 apt-get update')"
assert_eq "0" "$(ds_call_count sudo 'apt-get install *')"

# The bridge needs the system curl: the check names it when it is missing.
sudo dpkg -r curl >/dev/null
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt package curl is not installed (the apt bridge runs it)"
assert_exit 0 run_install --profile fresh
assert_eq "8.5.0" "$(ds_dpkg_version curl)"

# Another architecture picks its own asset; one without an asset is refused
# before any download or sudo call.
ds_stub_set dpkg architecture arm64
rm -f -- "$conf"
assert_exit 0 run_install --profile fresh
assert_contains "$(<"$conf")" "architecture=arm64
url=https://github.com/example-org/example-app/releases/latest/download
asset=example-app-{version}-linux-aarch64.deb"
ds_stub_set dpkg architecture riscv64
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "example-app (deb): githubRelease names no asset for architecture riscv64"
assert_eq "0" "$(ds_call_count sudo)"
ds_stub_set dpkg architecture amd64

# The bridge serves the first package name, so it needs one.
manifest_edit '(.components[] | select(.name == "example-app") | .install) |= (.pin = null | .packageNames = [])'
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "example-app (deb): githubRelease needs packageNames"

# Adopt mode does not manage system packages: nothing is written.
manifest_edit '(.components[] | select(.name == "example-app") | .install) |= (.pin = "desktop_packages.example-app" | .packageNames = ["example-app"])'
rm -f -- "$script" "$conf" "$hook" "$source_file"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation
assert_eq "0" "$(ds_call_count sudo)"
[[ ! -e $script && ! -e $hook ]] || ds_fail "adopt mode wrote the bridge"
