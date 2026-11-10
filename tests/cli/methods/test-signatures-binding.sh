# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # methods shell snippets are single-quoted on purpose
# A recorded signature is bound to what is installed, at install time
# (offline, with the real cosign), against an attacker who can replace the
# release assets but not the lock or the signing workflow:
#   - the signature of an archive member covers the member the component
#     installs, by its full path: a signed file elsewhere in the archive does
#     not vouch for another one, and of two archive entries with that path the
#     one tar leaves on disk, which is installed, is the one verified;
#   - a member reached through a directory link of the archive is refused;
#   - the identity of the signature is the recorded one, and its tag names the
#     version of the pin, so the signature of an older release is no
#     signature of the pinned one;
#   - a source the lock knows as signed never installs without a signature,
#     whatever verify says;
#   - the signer's identity_regexp pins one identity: anchored at both ends,
#     no wildcard.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

command -v cosign >/dev/null || ds_fail "cosign is required by this test"
ds_use_stubs sudo curl
fixtures=$(ds_fixture common/sigstore)
issuer=https://token.actions.githubusercontent.com
identity=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v4.1.0
regexp='^https://github\.com/example/example-release/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
dest=$HOME/.local/bin/example-release
url=https://downloads.example.invalid/releases/v4.1.0/example-release-linux-x64.tar.gz
member=example-release-4.1.0/example-release

trust() {
  lock_set trust "$(jq -c --arg regexp "$1" --arg issuer "$issuer" '{
      sigstore_root: .,
      signers: { "agent_tools.example-release": { kind: "sigstore", identity_regexp: $regexp, issuer: $issuer, first_seen: "2026-11-01" } }
    }' "$fixtures/trusted_root.json")"
}
# signed SUBJECT [MEMBER]: records the 4.1.0 signature of SUBJECT (asset or member).
signed() {
  lock_set agent_tools.example-release.signature "$(jq -c --arg identity "$identity" --arg subject "$1" --arg member "${2:-}" \
    '{kind: "message", subject: $subject, identity: $identity, bundle: .} + (if $member == "" then {} else {member: $member} end)' \
    "$fixtures/example-release-4.1.0.sigstore.json")"
}
install_release() {
  in_methods_shell 'methods_official_binary_install example-release
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
# refused MESSAGE: the install stops with MESSAGE, nothing is installed and no
# attacker payload ran.
refused() {
  rm -f "$dest" "$HOME/PWNED"
  assert_exit 1 install_release
  assert_contains "$DS_STDERR" "$1"
  [[ ! -e $dest ]] || ds_fail "dest was installed: $1"
  [[ ! -e $HOME/PWNED ]] || ds_fail "the attacker payload ran"
  assert_eq "" "$(temp_dirs)"
}
evil() {
  printf 'printf "example-release %%s\\n" %s; : >"$HOME/PWNED"\n' "$2" >"$1"
  chmod 0755 "$1"
}

add_component example-release official-binary '{
  "pin": "agent_tools.example-release",
  "asset": {"linux": "example-release-linux-x64.tar.gz"},
  "member": "example-release-{version}/example-release",
  "dest": "~/.local/bin/example-release",
  "versionArgv": ["--version"],
  "versionRegex": "example-release ([0-9][0-9.]*)",
  "policy": "exact",
  "verify": "sha256+sigstore"
}'
trust "$regexp"

# --- The signed file sits elsewhere in the archive; the installed member is
# the attacker's.
work=$DS_TEST_ROOT/elsewhere
mkdir -p "$work/signed" "$work/example-release-4.1.0"
cp "$fixtures/example-release-4.1.0" "$work/signed/example-release"
evil "$work/$member" 4.1.0
tar -czf "$DS_TEST_ROOT/elsewhere.tar.gz" -C "$work" signed example-release-4.1.0
pin_download agent_tools.example-release "$DS_TEST_ROOT/elsewhere.tar.gz" "$url" 4.1.0
signed member signed/example-release
refused "example-release (official-binary): the signature in versions.lock.json agent_tools.example-release covers signed/example-release, and the component installs $member"

# --- Two entries with the installed path: the first is the signed file, the
# second (the one tar leaves on disk) the attacker's.
mkdir -p "$DS_TEST_ROOT/first/example-release-4.1.0" "$DS_TEST_ROOT/second/example-release-4.1.0"
cp "$fixtures/example-release-4.1.0" "$DS_TEST_ROOT/first/$member"
chmod 0755 "$DS_TEST_ROOT/first/$member"
evil "$DS_TEST_ROOT/second/$member" 4.1.0
tar -cf "$DS_TEST_ROOT/twice.tar" -C "$DS_TEST_ROOT/first" "$member"
tar -rf "$DS_TEST_ROOT/twice.tar" -C "$DS_TEST_ROOT/second" "$member"
gzip -n -f "$DS_TEST_ROOT/twice.tar"
pin_download agent_tools.example-release "$DS_TEST_ROOT/twice.tar.gz" "$url" 4.1.0
signed member "$member"
refused "example-release (official-binary): the sigstore signature of $member does not verify: "

# --- The installed member reached through a directory link of the archive.
outside=$DS_TEST_ROOT/outside
mkdir -p "$outside/example-release-4.1.0" "$DS_TEST_ROOT/linked"
cp "$fixtures/example-release-4.1.0" "$outside/$member"
chmod 0755 "$outside/$member"
ln -s "$outside/example-release-4.1.0" "$DS_TEST_ROOT/linked/example-release-4.1.0"
tar -czf "$DS_TEST_ROOT/linked.tar.gz" -C "$DS_TEST_ROOT/linked" example-release-4.1.0
pin_download agent_tools.example-release "$DS_TEST_ROOT/linked.tar.gz" "$url" 4.1.0
signed member "$member"
refused "example-release (official-binary): archive member $member leads out of the archive through a link: $url"

# The genuine archive installs.
work=$DS_TEST_ROOT/genuine
mkdir -p "$work/example-release-4.1.0"
cp "$fixtures/example-release-4.1.0" "$work/$member"
chmod 0755 "$work/$member"
tar -czf "$DS_TEST_ROOT/genuine.tar.gz" -C "$work" example-release-4.1.0
pin_download agent_tools.example-release "$DS_TEST_ROOT/genuine.tar.gz" "$url" 4.1.0
signed member "$member"
assert_exit 0 install_release
assert_eq "installed: example-release 4.1.0" "${DS_STDOUT##*$'\n'}"

# --- The signature of an older release at the place of a newer one: the bytes
# are genuine and signed, but by the release of tag v4.1.0, and the pin is 5.0.0.
manifest_edit '(.components[] | select(.name == "example-release") | .install.member) = "example-release"'
raw_url=https://downloads.example.invalid/releases/v5.0.0/example-release-linux-x64
pin_download agent_tools.example-release "$fixtures/example-release-4.1.0" "$raw_url" 5.0.0
signed asset
refused "example-release (official-binary): the signature in versions.lock.json agent_tools.example-release is of $identity, which does not name version 5.0.0 of the pin"
# The recorded identity is the one verified: another one in the lock (that
# matches the signer and names the same version) is refused.
pin_download agent_tools.example-release "$fixtures/example-release-4.1.0" "$raw_url" 4.1.0
identity=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v04.1.0
signed asset
refused "example-release (official-binary): the sigstore signature of example-release-linux-x64 does not verify: "
identity=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags/v4.1.0

# --- A signed source with the signature gone from its entry: never unsigned,
# with either verify.
manifest_edit '(.components[] | select(.name == "example-release") | .install.verify) = "sha256"'
pin_download agent_tools.example-release "$fixtures/example-release-4.1.0" "$raw_url" 4.1.0
: >"$DS_CALL_LOG"
refused "example-release (official-binary): trust.signers of versions.lock.json knows agent_tools.example-release as signed, and its entry records no signature; run 'dotsteward pins apply'"
assert_eq "0" "$(ds_call_count curl)"

# --- An identity_regexp that does not pin one identity.
signed asset
for loose in '.*' 'github\.com/example/' '^https://github\.com/example/.*$' '^https://github\.com/example/(example-release|example-fork)/.+$'; do
  trust "$loose"
  refused "example-release (official-binary): the signer of agent_tools.example-release in versions.lock.json has an identity_regexp that does not pin one identity"
done
trust "$regexp"
assert_exit 0 install_release
assert_eq "installed: example-release 4.1.0" "${DS_STDOUT##*$'\n'}"
