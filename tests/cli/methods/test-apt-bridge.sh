# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The local APT bridge (cli/libexec/apt-bridge.sh) that a deb component
# with install.githubRelease puts on the machine. A system timer runs it as
# root, outside any apt lock, with the configuration directory and the
# repository directory; the deb transaction and any other caller run it the
# same way on its own. For each <package>.conf it reads the checksum
# file of the newest release, picks the one asset that matches the template of
# the machine's architecture and, when the repository does not hold that file
# yet, downloads it, checks its SHA-256 and that its control fields name the
# package and the architecture, lists it as the only version of the package
# and commits the flat repository index (Packages and Release). Any failure
# keeps the repository as it was, prints one line and still exits 0.
#
# APT reads the repository at any moment: a DEB lands by rename, one rename
# (of Release) commits an index, by-hash keeps the indexes of before the commit
# for a day, and a DEB the index no longer lists stays until the next version
# arrives.
# tests/cli/methods/test-apt-bridge-real-apt.sh shows what a real APT makes of
# all this.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs curl dpkg dpkg-deb

bridge=$DS_REPO_ROOT/cli/libexec/apt-bridge.sh
[[ -f $bridge ]] || ds_fail "the bridge script is missing: $bridge"
conf_dir=$DS_SYSTEM_ROOT/etc/dotsteward/apt-bridge.d
repo=$DS_SYSTEM_ROOT/var/lib/dotsteward/apt-bridge
base=https://github.com/example-org/example-app/releases/latest/download
mkdir -p "$conf_dir"
cat >"$conf_dir/example-app.conf" <<EOF
package=example-app
architecture=amd64
url=$base
asset=example-app-{version}-linux-x86_64.deb
checksums=SHA256SUMS.txt
EOF

# release VERSION [PACKAGE] [ARCH]: serves a release whose checksum file
# lists the DEB of VERSION (built with PACKAGE and ARCH) and an unrelated
# asset; prints the SHA-256 of the DEB.
release() {
  local version=$1 package=${2:-example-app} arch=${3:-amd64} dir deb sha
  dir=$DS_TEST_ROOT/release-$version-$package-$arch
  mkdir -p "$dir"
  deb=$dir/example-app-$version-linux-x86_64.deb
  ds_fake_deb "$deb" "$package" "$version" "$arch"
  printf 'other\n' >"$dir/example-app-$version-linux-aarch64.deb"
  sha=$(sha256sum "$deb" | cut -d' ' -f1)
  {
    printf '%s  %s\n' "$(sha256sum "$dir/example-app-$version-linux-aarch64.deb" | cut -d' ' -f1)" \
      "example-app-$version-linux-aarch64.deb"
    printf '%s *%s\n' "$sha" "example-app-$version-linux-x86_64.deb"
  } >"$dir/SHA256SUMS.txt"
  ds_curl_serve "$base/SHA256SUMS.txt" "$dir/SHA256SUMS.txt"
  ds_curl_serve "$base/example-app-$version-linux-x86_64.deb" "$deb"
  printf '%s\n' "$sha"
}

run_bridge() {
  bash "$bridge" "$conf_dir" "$repo"
}

pool() {
  find "$repo" -maxdepth 1 -name '*.deb' -printf '%f\n' | sort
}

# The DEBs the index lists.
listed() {
  sed -n 's|^Filename: \./||p' "$repo/Packages" | sort
}

# The digests of the indexes by-hash keeps.
by_hash() {
  find "$repo/by-hash/SHA256" -type f -printf '%f\n' | sort
}

digest() {
  sha256sum "$1" | cut -d' ' -f1
}

# First run: the DEB of the newest release becomes the repository's only
# package, with a flat index APT can read.
sha=$(release 1.2.0)
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: downloading example-app-1.2.0-linux-x86_64.deb
dotsteward-apt-bridge: example-app: 1.2.0 added" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_eq "example-app_1.2.0_amd64.deb" "$(pool)"
assert_eq "2" "$(ds_call_count curl)" "the checksum file and the DEB"
assert_contains "$(ds_calls_of curl | head -n 1)" "--proto =https --tlsv1.2 "
assert_contains "$(ds_calls_of curl | head -n 1)" " $base/SHA256SUMS.txt"
assert_contains "$(<"$repo/Packages")" "Package: example-app
Version: 1.2.0
Architecture: amd64"
assert_contains "$(<"$repo/Packages")" "Filename: ./example-app_1.2.0_amd64.deb
Size: $(stat -c %s "$repo/example-app_1.2.0_amd64.deb")
SHA256: $sha"
assert_contains "$(<"$repo/Release")" "Label: dotsteward-apt-bridge"
assert_contains "$(<"$repo/Release")" "Acquire-By-Hash: yes"
assert_contains "$(<"$repo/Release")" "SHA256:
 $(sha256sum "$repo/Packages" | cut -d' ' -f1) $(stat -c %s "$repo/Packages") Packages"
assert_eq "$(<"$repo/Packages")" "$(<"$repo/by-hash/SHA256/$(digest "$repo/Packages")")"
release_before=$(<"$repo/Release")
[[ -z $(find "$repo" -mindepth 1 -maxdepth 1 -name '.partial*' -print) ]] ||
  ds_fail "a partial download was left behind"
# Root-owned in real life; readable by APT's unprivileged download user.
for file in "$repo/example-app_1.2.0_amd64.deb" "$repo/Packages" "$repo/Release" \
  "$repo/by-hash/SHA256/$(digest "$repo/Packages")"; do
  assert_file_mode "$file" 0644
done
for dir in "$repo" "$repo/by-hash" "$repo/by-hash/SHA256"; do
  assert_file_mode "$dir" 0755
done

# Second run with the same release: only the checksum file is read, the
# repository and its index are unchanged, nothing is printed.
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "" "$DS_STDOUT"
assert_eq "1" "$(ds_call_count curl)"
assert_eq "$release_before" "$(<"$repo/Release")"

# A newer release replaces the older package in the index. The older DEB stays
# on disk, for lists read before this run, and so does its index for an APT
# that read the Release of before the commit.
first_index=$(digest "$repo/Packages")
release 1.3.0 >/dev/null
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: downloading example-app-1.3.0-linux-x86_64.deb
dotsteward-apt-bridge: example-app: 1.3.0 added" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(listed)"
assert_eq "example-app_1.2.0_amd64.deb
example-app_1.3.0_amd64.deb" "$(pool)"
[[ -e $repo/example-app_1.2.0_amd64.deb.superseded ]] || ds_fail "the older DEB is not marked as superseded"
assert_contains "$(<"$repo/Packages")" "Version: 1.3.0"
assert_not_contains "$(<"$repo/Packages")" "Version: 1.2.0"
assert_eq "$(printf '%s\n' "$first_index" "$(digest "$repo/Packages")" | sort)" "$(by_hash)"
good_index=$(<"$repo/Packages")
second_index=$(digest "$repo/Packages")

# A DEB whose SHA-256 is not the listed one is refused; the repository keeps
# the current package and the run still succeeds.
release 1.4.0 >/dev/null
printf 'tampered\n' >>"$DS_TEST_ROOT/release-1.4.0-example-app-amd64/example-app-1.4.0-linux-x86_64.deb"
ds_curl_serve "$base/example-app-1.4.0-linux-x86_64.deb" \
  "$DS_TEST_ROOT/release-1.4.0-example-app-amd64/example-app-1.4.0-linux-x86_64.deb"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: downloading example-app-1.4.0-linux-x86_64.deb
dotsteward-apt-bridge: example-app: the SHA-256 of example-app-1.4.0-linux-x86_64.deb is not the one in SHA256SUMS.txt; keeping the current package" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(listed)"
assert_eq "example-app_1.2.0_amd64.deb
example-app_1.3.0_amd64.deb" "$(pool)"
assert_eq "$good_index" "$(<"$repo/Packages")"

# A DEB of another package or another architecture is refused.
release 1.5.0 example-other >/dev/null
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: downloading example-app-1.5.0-linux-x86_64.deb
dotsteward-apt-bridge: example-app: example-app-1.5.0-linux-x86_64.deb holds package example-other (expected example-app); keeping the current package" "$DS_STDOUT"
release 1.6.0 example-app arm64 >/dev/null
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: downloading example-app-1.6.0-linux-x86_64.deb
dotsteward-apt-bridge: example-app: example-app-1.6.0-linux-x86_64.deb is built for arm64 (expected amd64); keeping the current package" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(listed)"

# A checksum file without exactly one matching asset is refused.
printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "README.txt" >"$DS_TEST_ROOT/no-asset.txt"
ds_curl_serve "$base/SHA256SUMS.txt" "$DS_TEST_ROOT/no-asset.txt"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: SHA256SUMS.txt lists no asset example-app-{version}-linux-x86_64.deb; keeping the current package" "$DS_STDOUT"
{
  printf '%s  %s\n' "$(printf 'a%.0s' {1..64})" "example-app-2.0.0-linux-x86_64.deb"
  printf '%s  %s\n' "$(printf 'b%.0s' {1..64})" "example-app-2.0.1-linux-x86_64.deb"
} >"$DS_TEST_ROOT/two-assets.txt"
ds_curl_serve "$base/SHA256SUMS.txt" "$DS_TEST_ROOT/two-assets.txt"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: SHA256SUMS.txt lists more than one asset example-app-{version}-linux-x86_64.deb; keeping the current package" "$DS_STDOUT"

# A network failure keeps the repository and does not fail the update.
ds_curl_fail "$base/SHA256SUMS.txt" 6 "Could not resolve host: github.com"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: cannot download SHA256SUMS.txt (curl exit 6); keeping the current package" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(listed)"
assert_eq "$good_index" "$(<"$repo/Packages")"

# A configuration that names a non-HTTPS URL is ignored with a line; other
# packages are still served.
cat >"$conf_dir/example-term.conf" <<'EOF'
package=example-term
architecture=amd64
url=http://downloads.example.invalid/latest
asset=example-term-{version}.deb
checksums=SHA256SUMS.txt
EOF
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: cannot download SHA256SUMS.txt (curl exit 6); keeping the current package
dotsteward-apt-bridge: example-term: refusing a non-HTTPS URL: http://downloads.example.invalid/latest" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(listed)"
rm -f -- "$conf_dir/example-term.conf"

# The next version takes the superseded DEB. An index stays for a day: a run
# can commit several in a row, and an APT that read a Release must still find
# what it names when more than one commit follows.
rm -f -- "$(_ds_curl_path "$base/SHA256SUMS.txt").exit"
release 1.7.0 >/dev/null
assert_exit 0 run_bridge
assert_eq "example-app_1.7.0_amd64.deb" "$(listed)"
assert_eq "example-app_1.3.0_amd64.deb
example-app_1.7.0_amd64.deb" "$(pool)"
[[ ! -e $repo/example-app_1.2.0_amd64.deb.superseded ]] || ds_fail "the marker of a removed DEB stayed"
assert_eq "$(printf '%s\n' "$first_index" "$second_index" "$(digest "$repo/Packages")" | sort)" "$(by_hash)"

# The vendor goes back to the release before: the DEB it still has is listed
# again without a download, and the one it left is the superseded one now.
release 1.3.0 >/dev/null
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: back to example-app-1.3.0-linux-x86_64.deb" "$DS_STDOUT"
assert_eq "1" "$(ds_call_count curl)"
assert_eq "example-app_1.3.0_amd64.deb" "$(listed)"
assert_eq "example-app_1.3.0_amd64.deb
example-app_1.7.0_amd64.deb" "$(pool)"
[[ -e $repo/example-app_1.7.0_amd64.deb.superseded && ! -e $repo/example-app_1.3.0_amd64.deb.superseded ]] ||
  ds_fail "the markers do not follow the listed version"

# A release is dated after the one before, whatever the clock says.
LC_ALL=C sed -i "s/^Date: .*/Date: Sat, 01 Jan 2050 00:00:00 UTC/" "$repo/Release"
release 1.8.0 >/dev/null
assert_exit 0 run_bridge
assert_contains "$(<"$repo/Release")" "Date: Sat, 01 Jan 2050 00:00:01 UTC"

# One package at a time is committed: when the run ends in the download of a
# later package (the time limit of the service), the earlier one is listed. A
# run that a signal ended can leave its work directory, which APT never reads;
# the next run removes it.
cat >"$conf_dir/example-term.conf" <<EOF
package=example-term
architecture=amd64
url=https://downloads.example.invalid/latest
asset=example-term-{version}.deb
checksums=SHA256SUMS.txt
EOF
release 1.9.0 >/dev/null
printf '%s  %s\n' "$(printf 'c%.0s' {1..64})" example-term-1.0.0.deb >"$DS_TEST_ROOT/term-sums.txt"
ds_curl_serve https://downloads.example.invalid/latest/SHA256SUMS.txt "$DS_TEST_ROOT/term-sums.txt"
ds_curl_delay https://downloads.example.invalid/latest/example-term-1.0.0.deb 300
mkdir -p "$repo/.partial.killed"
: >"$repo/.partial.killed/example-app-1.9.0-linux-x86_64.deb"
: >"$DS_CALL_LOG"
timeout --kill-after=60 600 bash "$bridge" "$conf_dir" "$repo" >/dev/null 2>&1 &
limited_run=$!
ds_defer kill -KILL -- "-$limited_run"
for ((i = 0; i < 1200; i++)); do
  (($(ds_call_count curl '*example-term-1.0.0.deb*') > 0)) && break
  sleep 0.1
done
assert_eq "1" "$(ds_call_count curl '*example-term-1.0.0.deb*')"
assert_eq "example-app_1.9.0_amd64.deb" "$(listed)"
[[ ! -e $repo/.partial.killed ]] || ds_fail "the run kept the work directory of a killed run"
kill -TERM "$limited_run"
wait "$limited_run" || true
assert_eq "example-app_1.9.0_amd64.deb" "$(listed)"
rm -f -- "$conf_dir/example-term.conf"

# An index of an older framework (no by-hash, no Acquire-By-Hash) is brought to
# this form without a download of anything held.
rm -rf -- "$repo/by-hash"
LC_ALL=C sed -i '/^Acquire-By-Hash: /d' "$repo/Release"
index_before=$(<"$repo/Packages")
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "1" "$(ds_call_count curl)"
assert_eq "$index_before" "$(<"$repo/Packages")"
assert_contains "$(<"$repo/Release")" "Acquire-By-Hash: yes"
[[ -f $repo/by-hash/SHA256/$(digest "$repo/Packages") ]] || ds_fail "by-hash lacks the index"
[[ -z $(find "$repo" -mindepth 1 -maxdepth 1 -name '.partial*' -print) ]] ||
  ds_fail "a work directory stayed after a full run"

# After a day an index goes, unless the Release until now names it.
current_index=$(digest "$repo/Packages")
mkdir -p "$repo/by-hash/SHA256"
printf 'an older index\n' >"$repo/by-hash/SHA256/$(printf 'd%.0s' {1..64})"
find "$repo/by-hash/SHA256" -type f -exec touch -d '2 days ago' {} +
release 2.0.0 >/dev/null
assert_exit 0 run_bridge
assert_eq "$(printf '%s\n' "$current_index" "$(digest "$repo/Packages")" | sort)" "$(by_hash)"

# A power cut can leave what a commit renamed empty, since a rename can reach
# the disk before the data does. The next run does not take that for a
# committed index.
release_before=$(<"$repo/Release")
good_index=$(<"$repo/Packages")
: >"$repo/by-hash/SHA256/$(digest "$repo/Packages")"
assert_exit 0 run_bridge
assert_eq "$good_index" "$(<"$repo/by-hash/SHA256/$(sed -n 's/^ \([0-9a-f]\{64\}\) [0-9]* Packages$/\1/p' "$repo/Release")")"
: >"$repo/Packages"
assert_exit 0 run_bridge
assert_eq "$good_index" "$(<"$repo/Packages")"

# A run killed between the rename of a DEB and marking the one before leaves
# two unmarked DEBs. Nothing is left to download, and the next run still lists
# the one the vendor names.
held=$repo/example-app_2.0.0_amd64.deb
rm -f -- "$repo"/example-app_*.superseded
ds_fake_deb "$repo/example-app_1.9.5_amd64.deb" example-app 1.9.5 amd64
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "1" "$(ds_call_count curl)"
assert_eq "example-app_2.0.0_amd64.deb" "$(listed)"
[[ -e $repo/example-app_1.9.5_amd64.deb.superseded && ! -e $held.superseded ]] ||
  ds_fail "a run after the kill left the markers wrong"

# With DOTSTEWARD_CHECK_ONLY=1 nothing changes and nothing is downloaded.
state_before=$(find "$repo" -printf '%p %s %T@\n' | sort)
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_CHECK_ONLY=1 bash "$bridge" "$conf_dir" "$repo"
assert_contains "$DS_STDOUT" "check only"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "$state_before" "$(find "$repo" -printf '%p %s %T@\n' | sort)"
assert_exit 0 env DOTSTEWARD_CHECK_ONLY=1 bash "$bridge" "$conf_dir" "$DS_TEST_ROOT/no-repository"
[[ ! -e $DS_TEST_ROOT/no-repository ]] || ds_fail "the check-only run created the repository"

# Wrong usage only prints the usage: the script never fails its caller.
assert_exit 0 bash "$bridge" "$conf_dir"
assert_contains "$DS_STDERR" "usage: apt-bridge.sh CONF_DIR REPO_DIR"

# Without any configuration the repository is still a valid, empty one.
rm -rf -- "$conf_dir" "$repo"
assert_exit 0 run_bridge
assert_eq "" "$(<"$repo/Packages")"
assert_contains "$(<"$repo/Release")" "Label: dotsteward-apt-bridge"
