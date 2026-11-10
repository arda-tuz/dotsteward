# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # methods shell snippets are single-quoted on purpose
# Recorded sigstore signatures of downloads (offline, with the real cosign):
# a pin entry may record a `signature` (a Sigstore bundle, its kind, its
# subject: the downloaded asset or an archive member), and
# versions.lock.json `trust` records the signer of that pin (identity
# regular expression and OIDC issuer) and the trusted root. Every recorded
# signature is verified after the download and before anything is
# replaced, with the trusted root of the lock and no network; a signature
# that does not verify (another file, another signer, another issuer, a
# certificate authority the root does not name) stops the install and
# leaves the destination alone. official-binary with verify =
# "sha256+sigstore" also refuses a pin without a recorded signature before
# any download; without it an unsigned download is installed and reported
# as unsigned. A DEB with a recorded signature is checked the same way
# before the first sudo call.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

command -v cosign >/dev/null || ds_fail "cosign is required by this test"
ds_use_stubs sudo curl apt-get dpkg dpkg-query dpkg-deb
fixtures=$(ds_fixture common/sigstore)
issuer=https://token.actions.githubusercontent.com
identity=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v4.1.0
regexp='^https://github\.com/example/example-release/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
dest=$HOME/.local/bin/example-release
url=https://downloads.example.invalid/releases/v4.1.0/example-release-linux-x64.tar.gz

# make_release BLOB OUT: a tar.gz whose member example-release-4.1.0/example-release
# is BLOB, executable.
make_release() {
  local dir
  dir=$(mktemp -d "$DS_TEST_ROOT/release.XXXXXX")
  mkdir -p "$dir/example-release-4.1.0"
  cp -- "$1" "$dir/example-release-4.1.0/example-release"
  chmod 0755 "$dir/example-release-4.1.0/example-release"
  tar -czf "$2" -C "$dir" example-release-4.1.0
  rm -rf -- "$dir"
}

# signature KIND SUBJECT BUNDLE [EXTRA_JSON]: the signature object of a pin.
signature() {
  jq -c --arg kind "$1" --arg subject "$2" --arg identity "$identity" --argjson extra "${4:-"{}"}" \
    '{ kind: $kind, subject: $subject, identity: $identity, bundle: . } + $extra' "$3"
}

# trust REGEXP ISSUER: the trust section with the signer of the release pin.
# The signer of the DEB pin is always the same.
trust() {
  lock_set trust "$(jq -c --arg regexp "$1" --arg issuer "$2" '{
      sigstore_root: .,
      signers: {
        "agent_tools.example-release": { kind: "sigstore", identity_regexp: $regexp, issuer: $issuer, first_seen: "2026-11-01" },
        "desktop_packages.example-term": { kind: "sigstore",
          identity_regexp: "^https://github\\.com/example-org/example-term/\\.github/workflows/release\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$",
          issuer: "https://token.actions.githubusercontent.com", first_seen: "2026-11-01" }
      }
    }' "$fixtures/trusted_root.json")"
}

release=$DS_TEST_ROOT/example-release-4.1.0.tar.gz
make_release "$fixtures/example-release-4.1.0" "$release"
pin_download agent_tools.example-release "$release" "$url" 4.1.0
add_component example-release official-binary '{
  "pin": "agent_tools.example-release",
  "asset": {"linux": "example-release-linux-x64.tar.gz"},
  "member": "example-release-4.1.0/example-release",
  "dest": "~/.local/bin/example-release",
  "versionArgv": ["--version"],
  "versionRegex": "example-release ([0-9][0-9.]*)",
  "policy": "exact",
  "verify": "sha256+sigstore"
}'
member_signature=$(signature message member "$fixtures/example-release-4.1.0.sigstore.json" '{"member": "example-release-4.1.0/example-release"}')

install_release() {
  in_methods_shell 'methods_official_binary_install example-release
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
set_verify() {
  manifest_edit "(.components[] | select(.name == \"example-release\") | .install.verify) = \"$1\""
}
# refused MESSAGE: the install stops with MESSAGE and dest stays as it was.
refused() {
  local before
  before=$(sha256sum "$dest" 2>/dev/null || true)
  assert_exit 1 install_release
  assert_contains "$DS_STDERR" "$1"
  assert_eq "$before" "$(sha256sum "$dest" 2>/dev/null || true)"
  assert_eq "" "$(temp_dirs)"
}

# sha256+sigstore without a recorded signature: refused before any download.
trust "$regexp" "$issuer"
: >"$DS_CALL_LOG"
assert_exit 1 install_release
assert_eq "[dotsteward] ERROR: example-release (official-binary): verify = \"sha256+sigstore\" needs a recorded signature, and versions.lock.json agent_tools.example-release has none; run 'dotsteward pins apply' to record one" "$DS_STDERR"
assert_eq "0" "$(ds_call_count curl)"

# A signature of the archive member, verified after the extraction.
lock_set agent_tools.example-release.signature "$member_signature"
: >"$DS_CALL_LOG"
assert_exit 0 install_release
assert_eq "installed: example-release 4.1.0" "${DS_STDOUT##*$'\n'}"
assert_contains "$DS_STDOUT" "[dotsteward] example-release (official-binary): sigstore signature of example-release-4.1.0/example-release verified: $identity"
assert_eq "example-release 4.1.0" "$("$dest" --version)"
assert_eq "1" "$(ds_call_count curl)"
assert_eq "" "$(temp_dirs)"
installed=$(sha256sum "$dest")

# Another member than the signed one: the archive digest is right (the pin
# names it), the signature is not.
printf '# one more line\n' | cat "$fixtures/example-release-4.1.0" - >"$DS_TEST_ROOT/changed"
make_release "$DS_TEST_ROOT/changed" "$DS_TEST_ROOT/changed.tar.gz"
pin_download agent_tools.example-release "$DS_TEST_ROOT/changed.tar.gz" "$url" 4.1.0
lock_set agent_tools.example-release.signature "$member_signature"
rm -f "$dest"
refused "example-release (official-binary): the sigstore signature of example-release-4.1.0/example-release does not verify: "
[[ ! -e $dest ]] || ds_fail "dest written from a member the signature does not cover"

# The right bytes, but the lock names another signer, another issuer, or a
# trusted root without the certificate authority.
pin_download agent_tools.example-release "$release" "$url" 4.1.0
lock_set agent_tools.example-release.signature "$member_signature"
trust '^https://github\.com/example/example-fork/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' "$issuer"
refused "the sigstore signature of example-release-4.1.0/example-release does not verify: "
trust "$regexp" https://issuer.example.invalid
refused "the sigstore signature of example-release-4.1.0/example-release does not verify: "
trust "$regexp" "$issuer"
lock_set agent_tools.example-release.signature "$(signature message member "$fixtures/example-release-4.1.0.foreign.sigstore.json" '{"member": "example-release-4.1.0/example-release"}')"
refused "the sigstore signature of example-release-4.1.0/example-release does not verify: "
# A signature the trust section has no signer for.
lock_set agent_tools.example-release.signature "$member_signature"
lock_set trust "$(jq -c '{ sigstore_root: ., signers: {} }' "$fixtures/trusted_root.json")"
refused "example-release (official-binary): versions.lock.json agent_tools.example-release records a signature, but trust.signers has no sigstore signer for it"
trust "$regexp" "$issuer"
# A member the archive does not have.
lock_set agent_tools.example-release.signature "$(signature message member "$fixtures/example-release-4.1.0.sigstore.json" '{"member": "example-release-4.1.0/other"}')"
refused "example-release (official-binary): the signed member example-release-4.1.0/other is not a regular file in $url"

# The declared check is only the floor: with verify = "sha256" a recorded
# signature is still verified, and an unsigned download is installed and
# reported as unsigned.
set_verify sha256
pin_download agent_tools.example-release "$DS_TEST_ROOT/changed.tar.gz" "$url" 4.1.0
lock_set agent_tools.example-release.signature "$member_signature"
refused "the sigstore signature of example-release-4.1.0/example-release does not verify: "
pin_download agent_tools.example-release "$release" "$url" 4.1.0
# (A source the lock knows as signed never installs unsigned: this one is not.)
lock_set trust "$(jq -c '{ sigstore_root: ., signers: {} }' "$fixtures/trusted_root.json")"
assert_exit 0 install_release
trust "$regexp" "$issuer"
assert_eq "installed: example-release 4.1.0" "${DS_STDOUT##*$'\n'}"
assert_contains "$DS_STDOUT" "[dotsteward] example-release (official-binary): $url is unsigned: versions.lock.json agent_tools.example-release records no signature"
assert_eq "$installed" "$(sha256sum "$dest")"

# A signature of the asset itself (a plain binary), and a build provenance
# attestation of it (an in-toto statement in DSSE, a v0.3 bundle).
set_verify sha256+sigstore
manifest_edit '(.components[] | select(.name == "example-release") | .install.member) = "example-release"'
raw_url=https://downloads.example.invalid/releases/v4.1.0/example-release-linux-x64
pin_download agent_tools.example-release "$fixtures/example-release-4.1.0" "$raw_url" 4.1.0
lock_set agent_tools.example-release.signature "$(signature message asset "$fixtures/example-release-4.1.0.sigstore.json")"
rm -f "$dest"
assert_exit 0 install_release
assert_eq "installed: example-release 4.1.0" "${DS_STDOUT##*$'\n'}"
assert_contains "$DS_STDOUT" "sigstore signature of example-release-linux-x64 verified: $identity"
identity=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v5.0.0
pin_download agent_tools.example-release "$fixtures/example-release-5.0.0" "$raw_url" 5.0.0
lock_set agent_tools.example-release.signature "$(signature attestation asset "$fixtures/example-release-5.0.0.intoto.jsonl" '{"predicate_type": "https://slsa.dev/provenance/v1"}')"
assert_exit 0 install_release
assert_eq "installed: example-release 5.0.0" "${DS_STDOUT##*$'\n'}"
assert_contains "$DS_STDOUT" "sigstore attestation (https://slsa.dev/provenance/v1) of example-release-linux-x64 verified: $identity"
# The attestation names another file.
pin_download agent_tools.example-release "$fixtures/example-release-4.1.0" "$raw_url" 5.0.0
lock_set agent_tools.example-release.signature "$(signature attestation asset "$fixtures/example-release-5.0.0.intoto.jsonl" '{"predicate_type": "https://slsa.dev/provenance/v1"}')"
rm -f "$dest"
refused "the sigstore attestation (https://slsa.dev/provenance/v1) of example-release-linux-x64 does not verify: "

# A DEB with a recorded signature: verified before the first sudo call.
term_deb=$(ds_fixture common/debs/example-term_0.9.0_amd64.deb)
term_url=https://downloads.example.invalid/example-term_0.9.0_amd64.deb
pin_download desktop_packages.example-term "$term_deb" "$term_url" 0.9.0
add_component example-term deb '{"pin": "desktop_packages.example-term", "packageNames": ["example-term"], "architecture": "amd64", "verifyAfterInstall": true, "apt": []}'
identity=https://github.com/example-org/example-term/.github/workflows/release.yml@refs/tags/v0.9.0
lock_set desktop_packages.example-term.signature "$(signature message asset "$fixtures/example-release-4.1.0.sigstore.json")"
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh --component example-term
assert_contains "$DS_STDERR" "[dotsteward] ERROR: example-term (deb): the sigstore signature of example-term_0.9.0_amd64.deb does not verify: "
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "" "$(temp_dirs)"
lock_set desktop_packages.example-term.signature "$(signature message asset "$fixtures/example-term_0.9.0_amd64.deb.sigstore.json")"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh --component example-term
assert_contains "$DS_STDOUT" "[dotsteward] example-term (deb): sigstore signature of example-term_0.9.0_amd64.deb verified: $identity"
assert_eq "0.9.0" "$(ds_dpkg_version example-term)"
