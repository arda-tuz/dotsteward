# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A deb component whose vendor publishes DEBs as GitHub release assets but
# runs no APT repository names them with install.githubRelease. The deb
# transaction then puts the local APT bridge on the machine: the bridge
# script, one configuration per package (the release download URL and the
# asset of the machine's architecture), a oneshot service that runs the script
# and a timer that starts it, and a trusted flat file: source over the
# bridge repository; the system curl the script needs joins the transaction.
# A run can find no network, as on a laptop that just woke up, and nothing
# tells that from a day without a new release: the service waits for the
# network as apt's own daily service does, and the timer has four runs a day, so
# a failed one does not cost the day.
# Nothing downloads inside `apt-get update`: the transaction runs the script
# first (after its install when curl was missing), an APT hook of an older
# framework goes, and each file is written only when it differs, so a second
# run changes nothing. Later releases then arrive with plain
# `apt update && apt upgrade`. --check-only fails while a bridge file is
# missing or differs, the old hook is in place, the timer is not enabled or the
# repository has no index.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl systemctl
mkdir -p "$DS_SYSTEM_ROOT/run/systemd/system"
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
units=$DS_SYSTEM_ROOT/etc/systemd/system
service=$units/dotsteward-apt-bridge.service
timer=$units/dotsteward-apt-bridge.timer
timer_link=$units/timers.target.wants/dotsteward-apt-bridge.timer
assert_eq "$DS_SYSTEM_ROOT" "$DOTSTEWARD_SYSTEM_ROOT" "the harness points the system root at the fixture root"
mkdir -p "$apt_dir/apt.conf.d"

# The newest release of the vendor, newer than the pinned floor.
release_base=https://github.com/example-org/example-app/releases/latest/download
release_dir=$DS_TEST_ROOT/release
mkdir -p "$release_dir"
ds_fake_deb "$release_dir/example-app-1.3.0-linux-x86_64.deb" example-app 1.3.0 amd64
printf '%s  %s\n' "$(sha256sum "$release_dir/example-app-1.3.0-linux-x86_64.deb" | cut -d' ' -f1)" \
  example-app-1.3.0-linux-x86_64.deb >"$release_dir/SHA256SUMS.txt"
ds_curl_serve "$release_base/SHA256SUMS.txt" "$release_dir/SHA256SUMS.txt"
ds_curl_serve "$release_base/example-app-1.3.0-linux-x86_64.deb" "$release_dir/example-app-1.3.0-linux-x86_64.deb"

expected_conf="package=example-app
architecture=amd64
url=https://github.com/example-org/example-app/releases/latest/download
asset=example-app-{version}-linux-x86_64.deb
checksums=SHA256SUMS.txt"
expected_service="# Written by dotsteward: refreshes the local APT bridge outside any apt lock.
[Unit]
Description=Refresh the dotsteward local APT bridge
Wants=network-online.target
After=network-online.target
ConditionPathExists=$script

[Service]
Type=oneshot
ExecStartPre=-/usr/lib/apt/apt-helper wait-online
ExecStart=/bin/bash $script $DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d $repo
TimeoutStartSec=2h
Nice=19
IOSchedulingClass=idle
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dotsteward-apt-bridge"
expected_timer="# Written by dotsteward: refreshes the local APT bridge four times a day.
[Unit]
Description=Regular refresh of the dotsteward local APT bridge

[Timer]
OnCalendar=*-*-* 00/6:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target"
expected_source="Types: deb
URIs: file:$repo
Suites: ./
Trusted: yes
Signed-By: /dev/null
Check-Date: no"
old_hook_text="// Written by dotsteward: refreshes the local APT bridge before every update.
APT::Update::Pre-Invoke { \"if [ -f $script ]; then /bin/bash $script $DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d $repo || true; fi\"; };"

# Before anything is installed, --check-only names the missing bridge and
# changes nothing.
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file $script is missing"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count systemctl)"

# Fresh install: the pinned DEB is downloaded first, then the bridge's files,
# the timer and an empty index, the source, one update and one install that
# also brings the system curl; only now can the script reach the vendor, and
# one more update reads what it fetched.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$(<"$DS_REPO_ROOT/cli/libexec/apt-bridge.sh")" "$(<"$script")"
assert_eq "$expected_conf" "$(<"$conf")"
assert_eq "$expected_service" "$(<"$service")"
assert_eq "$expected_timer" "$(<"$timer")"
assert_eq "$expected_source" "$(<"$source_file")"
[[ ! -e $hook ]] || ds_fail "the deb method wrote an APT hook"
for file in "$script" "$conf" "$service" "$timer" "$source_file"; do
  assert_file_mode "$file" 0644
done
assert_symlink_to "$timer_link" "$timer"
assert_eq "active" "$(systemctl is-active dotsteward-apt-bridge.timer)"
assert_eq "1.2.3" "$(ds_dpkg_version example-app)"
assert_eq "8.5.0" "$(ds_dpkg_version curl)"
mapfile -t calls < <(grep -E '^(curl|sudo) ' "$DS_CALL_LOG")
assert_contains "${calls[0]}" " $app_url"
[[ ${calls[1]} == "sudo install -D -o root -g root -m 0644 $TMPDIR/dotsteward-install."*"/apt-bridge.sh $script" ]] ||
  ds_fail "unexpected script call: ${calls[1]}"
[[ ${calls[2]} == "sudo install -D -o root -g root -m 0644 "*" $conf" ]] || ds_fail "unexpected conf call: ${calls[2]}"
[[ ${calls[3]} == "sudo install -D -o root -g root -m 0644 "*" $service" ]] || ds_fail "unexpected service call: ${calls[3]}"
[[ ${calls[4]} == "sudo install -D -o root -g root -m 0644 "*" $timer" ]] || ds_fail "unexpected timer call: ${calls[4]}"
assert_eq "sudo systemctl daemon-reload" "${calls[5]}"
assert_eq "sudo systemctl enable --now dotsteward-apt-bridge.timer" "${calls[6]}"
assert_eq "sudo timeout 1800 bash $script /dev/null $repo" "${calls[7]}"
[[ ${calls[8]} == "sudo install -D -o root -g root -m 0644 "*" $source_file" ]] || ds_fail "unexpected source call: ${calls[8]}"
assert_eq "sudo timeout 600 apt-get update" "${calls[9]}"
[[ ${calls[10]} == "sudo apt-get install --no-install-recommends curl $TMPDIR/dotsteward-install."*"/example-app_1.2.3.deb" ]] ||
  ds_fail "unexpected install call: ${calls[10]}"
assert_eq "sudo timeout 1800 bash $script $DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d $repo" "${calls[11]}"
assert_contains "${calls[12]}" " $release_base/SHA256SUMS.txt"
assert_contains "${calls[13]}" " $release_base/example-app-1.3.0-linux-x86_64.deb"
assert_eq "sudo timeout 600 apt-get update" "${calls[14]}"
assert_eq 15 "${#calls[@]}" "one download, the files, the timer, an index, one update, one install, the refresh, one update"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): apt bridge: example-org/example-app, example-app-{version}-linux-x86_64.deb"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-app 1.2.3, curl"
assert_contains "$DS_STDOUT" "dotsteward-apt-bridge: example-app: 1.3.0 added"
assert_contains "$(<"$repo/Packages")" "Version: 1.3.0"
assert_eq "" "$(temp_dirs)"

# Everything current: no download, no sudo; --check-only passes.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"
assert_exit 0 run_install --profile fresh --check-only

# A machine with the system curl refreshes once, before its one update. A
# source that differs is written after the refresh.
printf 'changed\n' >>"$source_file"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file $source_file differs from the component"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$expected_source" "$(<"$source_file")"
mapfile -t calls < <(grep -E '^sudo ' "$DS_CALL_LOG")
assert_eq "sudo systemctl daemon-reload" "${calls[0]}"
assert_eq "sudo systemctl enable --now dotsteward-apt-bridge.timer" "${calls[1]}"
assert_eq "sudo timeout 1800 bash $script $DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d $repo" "${calls[2]}"
[[ ${calls[3]} == "sudo install -D -o root -g root -m 0644 "*" $source_file" ]] || ds_fail "unexpected source call: ${calls[3]}"
assert_eq "sudo timeout 600 apt-get update" "${calls[4]}"
assert_eq 5 "${#calls[@]}"

# A bridge file that differs fails the check and is rewritten alone; the
# rewrite triggers the update, no package is installed.
printf 'changed\n' >>"$timer"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file $timer differs from the component"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$expected_timer" "$(<"$timer")"
assert_eq "1" "$(ds_call_count sudo 'install *')"
assert_eq "1" "$(ds_call_count sudo 'systemctl daemon-reload')"
assert_eq "1" "$(ds_call_count sudo 'timeout 600 apt-get update')"
assert_eq "0" "$(ds_call_count sudo 'apt-get install *')"

# The hook of an older framework held the apt lock during its downloads: the
# check names it, and it goes first, before any update can run it.
printf '%s\n' "$old_hook_text" >"$hook"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): the obsolete apt bridge hook $hook is still in place"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
[[ ! -e $hook ]] || ds_fail "the install left the hook of an older framework"
assert_contains "$DS_STDOUT" "[dotsteward] apt bridge: removed the obsolete hook $hook"
mapfile -t calls < <(grep -E '^sudo ' "$DS_CALL_LOG")
assert_eq "sudo rm -f -- $hook" "${calls[0]}"
assert_eq "0" "$(ds_call_count sudo 'install *')"
assert_exit 0 run_install --profile fresh --check-only

# A timer that is not enabled is named and enabled again.
assert_exit 0 sudo systemctl disable --now dotsteward-apt-bridge.timer
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): the apt bridge timer dotsteward-apt-bridge.timer is not enabled"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_symlink_to "$timer_link" "$timer"
assert_eq "active" "$(systemctl is-active dotsteward-apt-bridge.timer)"
assert_eq "0" "$(ds_call_count sudo 'install *')"

# A repository without an index is named and written again.
rm -rf -- "$repo"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): the apt bridge repository $repo has no index"
assert_exit 0 run_install --profile fresh
assert_contains "$(<"$repo/Packages")" "Version: 1.3.0"
assert_exit 0 run_install --profile fresh --check-only

# A first refresh that cannot reach the vendor leaves the repository without
# the package. The install still ends well, since the package itself is in
# place, and says so; the check holds the machine to it, and the next install
# tries again.
rm -rf -- "$repo"
ds_curl_fail "$release_base/SHA256SUMS.txt" 6
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDERR" "example-app (deb): the apt bridge holds no release of example-app yet"
assert_eq "0" "$(ds_call_count sudo 'systemctl start *')" "no network now: a second run at once finds none either"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): the apt bridge repository $repo holds no release of example-app yet"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "1" "$(ds_call_count sudo 'timeout 1800 bash *')"
assert_contains "$DS_STDERR" "example-app (deb): the apt bridge holds no release of example-app yet"
rm -f -- "$(_ds_curl_path "$release_base/SHA256SUMS.txt").exit"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "dotsteward-apt-bridge: example-app: 1.3.0 added"
assert_not_contains "$DS_STDERR" "holds no release"
assert_exit 0 run_install --profile fresh --check-only

# Without a running systemd (a container, an image) the timer is enabled for
# the next boot.
rm -rf -- "$DS_SYSTEM_ROOT/run/systemd/system" "$timer_link"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_symlink_to "$timer_link" "$timer"
assert_eq "1" "$(ds_call_count sudo 'systemctl enable dotsteward-apt-bridge.timer')"
assert_eq "0" "$(ds_call_count sudo 'systemctl daemon-reload')"
mkdir -p "$DS_SYSTEM_ROOT/run/systemd/system"

# A machine without systemd at all has no timer to enable, and no check holds
# it to one.
no_systemctl=$(ds_path_without systemctl)
rm -f -- "$timer_link" "$timer"
without_systemctl() {
  env PATH="$no_systemctl" "$@"
}
assert_exit 0 without_systemctl "$methods_fw/cli/dotsteward" --instance "$methods_inst" install --profile fresh
assert_contains "$DS_STDERR" "apt bridge: this machine has no systemctl, so no timer refreshes $repo"
[[ ! -e $timer_link ]] || ds_fail "the timer was enabled without systemctl"
assert_exit 0 without_systemctl "$methods_fw/cli/dotsteward" --instance "$methods_inst" install --profile fresh --check-only
assert_exit 0 run_install --profile fresh
assert_symlink_to "$timer_link" "$timer"

# A failed enable stops the transaction before its update.
ds_stub_route systemctl 'enable --now *' --exit 1 --stderr 'Failed to enable unit: Access denied'
rm -f -- "$timer_link"
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "apt bridge: cannot enable dotsteward-apt-bridge.timer"
assert_eq "0" "$(ds_call_count sudo 'timeout 600 apt-get update')"
ds_stub_clear_routes systemctl
assert_exit 0 run_install --profile fresh

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

# Adopt mode does not manage system packages: nothing is written, and its
# profile check does not ask for the bridge.
manifest_edit '(.components[] | select(.name == "example-app") | .install) |= (.pin = "desktop_packages.example-app" | .packageNames = ["example-app"])'
rm -f -- "$script" "$conf" "$source_file" "$service" "$timer" "$timer_link"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation
assert_eq "0" "$(ds_call_count sudo)"
assert_exit 0 run_install --profile workstation --check-only
assert_contains "$DS_STDOUT" "example-app (deb): not-managed: system-level method in adopt mode"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count systemctl)"
[[ ! -e $script && ! -e $timer ]] || ds_fail "adopt mode wrote the bridge"

# Named with --component, an adopted machine takes in the bridge like a fresh
# one, the hook of the older framework goes, and the check of the named
# component holds it to the result.
assert_exit 1 run_install --profile workstation --check-only --component example-app
assert_contains "$DS_STDERR" "example-app (deb): apt bridge file $script is missing"
printf '%s\n' "$old_hook_text" >"$hook"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation --component example-app
assert_eq "$expected_timer" "$(<"$timer")"
assert_eq "$expected_service" "$(<"$service")"
assert_eq "$expected_source" "$(<"$source_file")"
assert_symlink_to "$timer_link" "$timer"
[[ ! -e $hook ]] || ds_fail "the install of a named component left the hook of an older framework"
assert_exit 0 run_install --profile workstation --check-only --component example-app
