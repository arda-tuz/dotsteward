# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A deb component can name the vendor APT repositories its apt packages
# come from (install.aptSources). In fresh mode the signing key is
# downloaded over HTTPS before the first sudo call and must carry exactly
# the pinned primary key fingerprint; then the keyring and the deb822
# source file are written (only when they differ), before the one
# `apt-get update` and `apt-get install` of the transaction. A second run
# changes nothing. --check-only fails while a source or its keyring is
# missing or differs. The packages then update with plain apt, from the
# vendor repository.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl
command -v gpg >/dev/null || ds_fail "gpg is required by this test"

# Two synthetic signing keys made with the real gpg: the vendor's key and
# an unrelated one.
gpg_home=$DS_TEST_ROOT/gnupg
mkdir -m 0700 "$gpg_home"
make_key() {
  gpg --batch --quiet --homedir "$gpg_home" --passphrase '' --trust-model always \
    --quick-generate-key "$1" ed25519 sign never
  gpg --batch --quiet --homedir "$gpg_home" --armor --export "$1" >"$2"
  gpg --batch --homedir "$gpg_home" --with-colons --fingerprint "$1" |
    awk -F: '$1 == "fpr" { print $10; exit }'
}
vendor_key=$DS_TEST_ROOT/vendor.asc
other_key=$DS_TEST_ROOT/other.asc
vendor_fpr=$(make_key 'Example Vendor <repo@example.invalid>' "$vendor_key")
other_fpr=$(make_key 'Example Other <other@example.invalid>' "$other_key")
[[ $vendor_fpr =~ ^[0-9A-F]{40}$ && $vendor_fpr != "$other_fpr" ]] ||
  ds_fail "unexpected fingerprints: $vendor_fpr $other_fpr"

key_url=https://apt.example.invalid/linux/ubuntu/gpg
ds_curl_serve "$key_url" "$vendor_key"
ds_apt_available example-cli 1.0
ds_apt_available example-plugin 2.0

apt_dir=$DS_SYSTEM_ROOT/etc/apt
assert_eq "$apt_dir" "$DOTSTEWARD_APT_DIR" "the harness points the APT directory at the fixture root"
source_file=$apt_dir/sources.list.d/example-vendor.sources
keyring=$apt_dir/keyrings/example-vendor.asc
add_component example-app deb "$(jq -cn --arg url "$key_url" --arg fpr "$vendor_fpr" '{
  pin: null, packageNames: [], architecture: null, verifyAfterInstall: true,
  apt: ["example-cli", "example-plugin"],
  aptSources: [{
    name: "example-vendor",
    uri: "https://apt.example.invalid/linux/ubuntu",
    suites: ["{codename}"],
    components: ["stable"],
    architectures: ["amd64"],
    keyUrl: $url,
    keyFingerprint: $fpr
  }]
}')"
expected_source="Types: deb
URIs: https://apt.example.invalid/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: $keyring"

# Before anything is installed, --check-only names the missing source.
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt source example-vendor is not configured ($source_file)"

# Fresh install: the key download first, then the keyring and the source,
# then one update and one install.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$expected_source" "$(<"$source_file")"
assert_eq "$(<"$vendor_key")" "$(<"$keyring")"
assert_file_mode 0644 "$source_file"
assert_file_mode 0644 "$keyring"
assert_eq "1.0" "$(ds_dpkg_version example-cli)"
assert_eq "2.0" "$(ds_dpkg_version example-plugin)"
mapfile -t calls < <(grep -E '^(curl|sudo) ' "$DS_CALL_LOG")
assert_contains "${calls[0]}" "curl --proto =https --tlsv1.2 "
assert_contains "${calls[0]}" " $key_url"
[[ ${calls[1]} == "sudo install -D -o root -g root -m 0644 $TMPDIR/dotsteward-install."*"/example-vendor.asc $keyring" ]] ||
  ds_fail "unexpected keyring call: ${calls[1]}"
[[ ${calls[2]} == "sudo install -D -o root -g root -m 0644 $TMPDIR/dotsteward-install."*"/example-vendor.sources $source_file" ]] ||
  ds_fail "unexpected source call: ${calls[2]}"
assert_eq "sudo timeout 600 apt-get update" "${calls[3]}"
assert_eq "sudo apt-get install --no-install-recommends example-cli example-plugin" "${calls[4]}"
assert_eq 5 "${#calls[@]}" "one download, two files, one update, one install"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): apt source example-vendor: https://apt.example.invalid/linux/ubuntu noble stable"
assert_contains "$DS_STDOUT" "[dotsteward] example-app (deb): installed: example-cli, example-plugin"
assert_eq "" "$(temp_dirs)"

# Everything current: no download, no sudo; --check-only passes.
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "0" "$(ds_call_count curl)"
assert_eq "0" "$(ds_call_count sudo)"
assert_exit 0 run_install --profile fresh --check-only

# A source that differs (another suite) is rewritten; the keyring is kept.
# A source alone triggers the update, so the new suite is read before the
# packages update with plain apt.
sed -i 's/^Suites: noble$/Suites: jammy/' "$source_file"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): apt source example-vendor differs from the component ($source_file)"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_eq "$expected_source" "$(<"$source_file")"
assert_eq "0" "$(ds_call_count sudo "install * $keyring")"
assert_eq "1" "$(ds_call_count sudo "install * $source_file")"
assert_eq "1" "$(ds_call_count sudo 'timeout 600 apt-get update')"
assert_eq "0" "$(ds_call_count sudo 'apt-get install *')"

# A keyring with another key fails the check and is replaced.
cp -- "$other_key" "$keyring"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (deb): the keyring of apt source example-vendor does not hold exactly the key $vendor_fpr ($keyring)"
assert_exit 0 run_install --profile fresh
assert_eq "$(<"$vendor_key")" "$(<"$keyring")"

# A downloaded key with another fingerprint stops before any sudo call and
# writes nothing.
rm -f -- "$source_file" "$keyring"
ds_curl_serve "$key_url" "$other_key"
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "example-app (deb): the signing key at $key_url is not exactly the key $vendor_fpr (found $other_fpr)"
assert_eq "0" "$(ds_call_count sudo)"
[[ ! -e $source_file && ! -e $keyring ]] || ds_fail "a source was written for a wrong key"

# Two keys in one file are refused too, even when one of them matches.
cat -- "$vendor_key" "$other_key" >"$DS_TEST_ROOT/both.asc"
ds_curl_serve "$key_url" "$DS_TEST_ROOT/both.asc"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "example-app (deb): the signing key at $key_url is not exactly the key $vendor_fpr"
assert_eq "0" "$(ds_call_count sudo)"

# A key that cannot be downloaded stops the transaction the same way.
ds_curl_fail "$key_url" 22 "The requested URL returned error: 404"
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "example-app (deb): signing key download failed (curl exit 22): $key_url"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "" "$(temp_dirs)"

# Adopt mode does not manage system packages: no source is written.
ds_curl_serve "$key_url" "$vendor_key"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation
assert_eq "0" "$(ds_call_count sudo)"
[[ ! -e $source_file ]] || ds_fail "adopt mode wrote a source"
