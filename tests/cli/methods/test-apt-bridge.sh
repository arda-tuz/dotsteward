# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The local APT bridge (cli/libexec/apt-bridge.sh) that a deb component
# with install.githubRelease puts on the machine. APT runs it as root before
# every update (APT::Update::Pre-Invoke) with the configuration directory
# and the repository directory. For each <package>.conf it reads the
# checksum file of the newest release, picks the one asset that matches the
# template of the machine's architecture and, when the repository does not
# hold that file yet, downloads it, checks its SHA-256 and that its control
# fields name the package and the architecture, keeps it as the only
# version of the package, and rewrites the flat repository index (Packages
# and Release). Any failure keeps the repository as it was, prints one
# line and still exits 0, so `apt update` never breaks because of it.
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

# First run: the DEB of the newest release becomes the repository's only
# package, with a flat index APT can read.
sha=$(release 1.2.0)
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: 1.2.0 added" "$DS_STDOUT"
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
assert_contains "$(<"$repo/Release")" "SHA256:
 $(sha256sum "$repo/Packages" | cut -d' ' -f1) $(stat -c %s "$repo/Packages") Packages"
release_before=$(<"$repo/Release")
[[ -z $(find "$repo" -mindepth 1 -maxdepth 1 -name '.partial*' ! -empty -print) ]] ||
  ds_fail "a partial download was left behind"

# Second run with the same release: only the checksum file is read, the
# repository and its index are unchanged, nothing is printed.
: >"$DS_CALL_LOG"
assert_exit 0 run_bridge
assert_eq "" "$DS_STDOUT"
assert_eq "1" "$(ds_call_count curl)"
assert_eq "$release_before" "$(<"$repo/Release")"

# A newer release replaces the older package.
release 1.3.0 >/dev/null
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: 1.3.0 added" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(pool)"
assert_contains "$(<"$repo/Packages")" "Version: 1.3.0"
assert_not_contains "$(<"$repo/Packages")" "Version: 1.2.0"
good_index=$(<"$repo/Packages")

# A DEB whose SHA-256 is not the listed one is refused; the repository keeps
# the current package and the run still succeeds.
release 1.4.0 >/dev/null
printf 'tampered\n' >>"$DS_TEST_ROOT/release-1.4.0-example-app-amd64/example-app-1.4.0-linux-x86_64.deb"
ds_curl_serve "$base/example-app-1.4.0-linux-x86_64.deb" \
  "$DS_TEST_ROOT/release-1.4.0-example-app-amd64/example-app-1.4.0-linux-x86_64.deb"
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: the SHA-256 of example-app-1.4.0-linux-x86_64.deb is not the one in SHA256SUMS.txt; keeping the current package" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(pool)"
assert_eq "$good_index" "$(<"$repo/Packages")"

# A DEB of another package or another architecture is refused.
release 1.5.0 example-other >/dev/null
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: example-app-1.5.0-linux-x86_64.deb holds package example-other (expected example-app); keeping the current package" "$DS_STDOUT"
release 1.6.0 example-app arm64 >/dev/null
assert_exit 0 run_bridge
assert_eq "dotsteward-apt-bridge: example-app: example-app-1.6.0-linux-x86_64.deb is built for arm64 (expected amd64); keeping the current package" "$DS_STDOUT"
assert_eq "example-app_1.3.0_amd64.deb" "$(pool)"

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
assert_eq "example-app_1.3.0_amd64.deb" "$(pool)"
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
assert_eq "example-app_1.3.0_amd64.deb" "$(pool)"

# Without any configuration the repository is still a valid, empty one.
rm -rf -- "$conf_dir" "$repo"
assert_exit 0 run_bridge
assert_eq "" "$(<"$repo/Packages")"
assert_contains "$(<"$repo/Release")" "Label: dotsteward-apt-bridge"
