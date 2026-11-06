# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The local APT bridge as a real APT meets it: a real apt-get and apt-cache
# over a private root (no root rights needed) that read the apt.conf.d and
# sources.list.d the deb method wrote below the fixture root. The vendor,
# the package database and sudo are stubs; the fake DEBs are only listed,
# hashed and copied by APT, never unpacked.
#
# The defect it guards against: a bridge that downloads inside
# APT::Update::Pre-Invoke holds the lists lock of the apt-get update that runs
# it. When a software center or PackageKit starts a refresh at login on a weak
# network, the user's own `apt-get update` fails with "Could not get lock" or
# sits silently for many minutes. Downloads now happen outside any apt lock,
# and whatever moment an apt-get update reads the repository, it finds an
# index that holds together and a DEB behind every version it was promised.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

real_apt_get=$(command -v apt-get) || ds_fail "the real apt-get is required by this test"
real_apt_cache=$(command -v apt-cache) || ds_fail "the real apt-cache is required by this test"
apt_prefix=$(dirname "$(dirname "$(readlink -f "$real_apt_get")")")
apt_methods=$apt_prefix/lib/apt/methods
[[ -d $apt_methods ]] || apt_methods=$apt_prefix/libexec/apt/methods
[[ -d $apt_methods ]] || ds_fail "no APT methods next to the real apt-get: $apt_prefix"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl systemctl
mkdir -p "$DS_SYSTEM_ROOT/run/systemd/system"
ds_apt_available curl 8.5.0

base=https://github.com/example-org/example-app/releases/latest/download
script=$DS_SYSTEM_ROOT/usr/local/lib/dotsteward/apt-bridge.sh
conf_dir=$DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d
repo=$DS_SYSTEM_ROOT/var/lib/dotsteward/apt-bridge
service=$DS_SYSTEM_ROOT/etc/systemd/system/dotsteward-apt-bridge.service
source_file=$DOTSTEWARD_APT_DIR/sources.list.d/dotsteward-apt-bridge.sources

add_component example-app deb '{
  "pin": null, "packageNames": ["example-app"], "architecture": "amd64",
  "verifyAfterInstall": true, "apt": [], "aptSources": [],
  "githubRelease": {
    "repository": "example-org/example-app",
    "assets": {"amd64": "example-app-{version}-linux-x86_64.deb"},
    "checksums": "SHA256SUMS.txt"
  }
}'

# --- the private root of the real APT -------------------------------------
apt_root=$DS_TEST_ROOT/apt-root
apt_conf=$DS_TEST_ROOT/apt.conf
mkdir -p "$apt_root/var/lib/apt/lists/partial" "$apt_root/var/cache/apt/archives/partial" \
  "$apt_root/var/lib/dpkg" "$apt_root/var/log/apt" "$DOTSTEWARD_APT_DIR/apt.conf.d" \
  "$DOTSTEWARD_APT_DIR/preferences.d"
: >"$apt_root/var/lib/dpkg/status"
cat >"$apt_conf" <<CONF
Dir "$apt_root/";
Dir::Etc "$DOTSTEWARD_APT_DIR/";
Dir::Etc::main "apt.conf";
Dir::Etc::parts "apt.conf.d";
Dir::Etc::sourcelist "sources.list";
Dir::Etc::sourceparts "sources.list.d";
Dir::Etc::preferences "preferences";
Dir::Etc::preferencesparts "preferences.d";
Dir::State "var/lib/apt/";
Dir::State::status "$apt_root/var/lib/dpkg/status";
Dir::Cache "var/cache/apt/";
Dir::Log "var/log/apt/";
Dir::Bin::methods "$apt_methods/";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
APT::Sandbox::User "";
CONF

# A healthy apt-get update of this private root takes well under a second;
# the limit only tells a machine under load from one that waits for a download.
apt_limit=120

# real_apt PROGRAM ARG...: a real APT program over the private root, within
# the limit (status 124 past it), in a process group of its own.
real_apt() {
  APT_CONFIG=$apt_conf timeout --kill-after=5 "$apt_limit" "$@"
}

# Notices stay visible: without a terminal, APT hides them unless asked.
real_update() {
  real_apt "$real_apt_get" -o quiet=0 update
}

candidate() {
  real_apt "$real_apt_cache" policy example-app | sed -n 's/^ *Candidate: //p'
}

forget_lists() {
  rm -rf -- "$apt_root/var/lib/apt/lists"
  mkdir -p "$apt_root/var/lib/apt/lists/partial"
}

# release VERSION: the vendor publishes VERSION as its newest release.
release() {
  local version=$1 dir deb
  dir=$DS_TEST_ROOT/release-$version
  mkdir -p "$dir"
  deb=$dir/example-app-$version-linux-x86_64.deb
  ds_fake_deb "$deb" example-app "$version" amd64
  printf '%s  %s\n' "$(sha256sum "$deb" | cut -d' ' -f1)" "${deb##*/}" >"$dir/SHA256SUMS.txt"
  ds_curl_serve "$base/SHA256SUMS.txt" "$dir/SHA256SUMS.txt"
  ds_curl_serve "$base/${deb##*/}" "$deb"
}

wait_for_curl() {
  local i
  for ((i = 0; i < 1200; i++)); do
    (($(ds_call_count curl "$1") > 0)) && return 0
    sleep 0.1
  done
  ds_fail "the curl stub saw no call matching $1"
}

# run_bridge: one run of the bridge, on its own or as the service starts it.
run_bridge() {
  bash "$script" "$conf_dir" "$repo"
}

# --- installed, with one version served -----------------------------------
release 1.2.0
assert_exit 0 run_install --profile fresh
assert_exit 0 real_update
assert_eq "1.2.0" "$(candidate)"
assert_contains "$(real_apt "$real_apt_cache" policy example-app)" "file:$repo ./ Packages"

# --- reproduction: a vendor download hangs while PackageKit refreshes -----
release 1.3.0
new_deb=example-app-1.3.0-linux-x86_64.deb
ds_curl_delay "$base/$new_deb" 300
packagekit_log=$DS_TEST_ROOT/packagekit.log
real_update >"$packagekit_log" 2>&1 &
packagekit=$!
for ((i = 0; i < 1000; i++)); do
  kill -0 "$packagekit" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$packagekit" 2>/dev/null; then
  second=$(real_update 2>&1) && second_status=0 || second_status=$?
  kill -TERM "$packagekit" 2>/dev/null || true
  wait "$packagekit" || true
  ds_fail "apt-get update waits for the vendor download and holds the lock: a second one exits $second_status with [$second]"
fi
wait "$packagekit" || ds_fail "the apt-get update that met a slow vendor failed: $(<"$packagekit_log")"
assert_eq "1.2.0" "$(candidate)" "the version already fetched stays on offer"
assert_eq "0" "$(ds_call_count curl "*$new_deb*")" "apt-get update starts no download"

# No hook at all, and no note about the unsigned local source.
if matches=$(grep -rl 'Pre-Invoke' "$DOTSTEWARD_APT_DIR/apt.conf.d"); then
  ds_fail "an APT hook is still written: $matches"
fi
assert_exit 0 real_update
assert_not_contains "$DS_STDOUT$DS_STDERR" "Missing Signed-By"

# --- the timer's run hangs in the download: APT does not notice -----------
[[ $(sed -n 's/^ExecStart=//p' "$service") == "/bin/bash $script $conf_dir $repo" ]] ||
  ds_fail "the service does not run the bridge script: $(<"$service")"
index_before=$(<"$repo/Packages")
release_before=$(<"$repo/Release")
: >"$DS_CALL_LOG"
# timeout runs it in a process group of its own and passes a signal on to all
# of it, as systemd does for a service.
timeout --kill-after=60 600 bash "$script" "$conf_dir" "$repo" >"$DS_TEST_ROOT/timer-run.log" 2>&1 &
timer_run=$!
ds_defer kill -KILL -- "-$timer_run"
wait_for_curl "*$new_deb*"

forget_lists
assert_exit 0 real_update
assert_not_contains "$DS_STDOUT$DS_STDERR" "Could not get lock"
assert_eq "1.2.0" "$(candidate)"
assert_eq "$index_before" "$(<"$repo/Packages")"
assert_eq "$release_before" "$(<"$repo/Release")"

# One run at a time: a second one that may not wait changes nothing.
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_APT_BRIDGE_LOCK_WAIT=0 bash "$script" "$conf_dir" "$repo"
assert_contains "$DS_STDOUT" "dotsteward-apt-bridge: another run holds $repo/.lock; skipped"
assert_eq "0" "$(ds_call_count curl)"

# The service's time limit ends the hanging run: APT sees nothing of it.
kill -TERM "$timer_run"
wait "$timer_run" || true
assert_eq "$index_before" "$(<"$repo/Packages")"
assert_eq "$release_before" "$(<"$repo/Release")"

# --- the download works again: new index, the old promise still holds -----
ds_curl_delay "$base/$new_deb" 0
assert_exit 0 run_bridge
assert_contains "$DS_STDOUT" "dotsteward-apt-bridge: example-app: 1.3.0 added"
assert_not_contains "$(<"$repo/Packages")" "Version: 1.2.0"
[[ -z $(find "$repo" -maxdepth 1 -name '.partial*' -print) ]] || ds_fail "a work directory stayed after a full run"

# Lists from before the refresh still promise 1.2.0: `apt upgrade` finds it.
assert_eq "1.2.0" "$(candidate)"
assert_exit 0 real_apt "$real_apt_get" -y --download-only install example-app
assert_contains "$DS_STDOUT" "example-app 1.2.0"

# The next update offers the new version.
assert_exit 0 real_update
assert_eq "1.3.0" "$(candidate)"
assert_exit 0 real_apt "$real_apt_get" -y --download-only install example-app
assert_contains "$DS_STDOUT" "example-app 1.3.0"

# --- every moment of a commit: Release and Packages out of step ------------
index_new=$(<"$repo/Packages")
release_new=$(<"$repo/Release")

# APT read the Release of before the commit and fetches Packages after it.
printf '%s\n' "$release_before" >"$repo/Release"
forget_lists
assert_exit 0 real_update
assert_not_contains "$DS_STDOUT$DS_STDERR" "Hash Sum mismatch"
assert_eq "1.2.0" "$(candidate)"

# The new Release is in place and the plain Packages is still the old one.
printf '%s\n' "$release_new" >"$repo/Release"
printf '%s\n' "$index_before" >"$repo/Packages"
forget_lists
assert_exit 0 real_update
assert_not_contains "$DS_STDOUT$DS_STDERR" "Hash Sum mismatch"
assert_eq "1.3.0" "$(candidate)"
printf '%s\n' "$index_new" >"$repo/Packages"

# --- a clock that went back ---------------------------------------------------
# A Release dated ahead of the clock is no error for this local source, and
# the next index is dated after it: APT silently ignores an older one.
tomorrow=$(LC_ALL=C date -u -d '+1 day' '+%a, %d %b %Y %H:%M:%S UTC')
sed -i "s/^Date: .*/Date: $tomorrow/" "$repo/Release"
assert_exit 0 real_update
assert_not_contains "$DS_STDOUT$DS_STDERR" "not valid yet"
release 1.4.0
assert_exit 0 run_bridge
assert_exit 0 real_update
assert_eq "1.4.0" "$(candidate)"

# --- the first refresh of a machine hangs -----------------------------------
# The bridge's source only appears once the repository is readable, the
# install does not wait without end, and APT reads a valid, empty index.
rm -rf -- "$repo" "$source_file" "$script" "$service" "$conf_dir"
forget_lists
ds_curl_delay "$base/SHA256SUMS.txt" 300
assert_exit 0 env DOTSTEWARD_APT_BRIDGE_TIMEOUT=10 "$methods_fw/cli/dotsteward" --instance "$methods_inst" install --profile fresh
assert_contains "$DS_STDERR" "the refresh did not finish within 10 s"
assert_exit 0 real_update
assert_eq "" "$(candidate)"
