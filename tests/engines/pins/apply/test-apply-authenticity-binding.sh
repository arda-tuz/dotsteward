# shellcheck shell=bash
# What the writer verifies is what will be installed, against an attacker who
# can replace the release assets but not the signing workflow or the lock:
#   - the signature of an archive member is checked on the member the
#     component installs (install.member, by its full path); a signed file
#     elsewhere in the archive, or a second entry with that path, does not
#     count, and the archive is the one whose digest the pin records;
#   - the identity's tag names the version the pin moves to (no replay of the
#     signature of an older release);
#   - on first use the signer must be a workflow of the pin's own repository
#     (no fork pinned as the signer);
#   - a signature lookup without an answer (no network, a server error) is no
#     answer: the pin waits for the next run (exit 6), with no review item that
#     claims the signature is gone, and an unsigned source still moves;
#   - pins check refuses a signed source whose entry records no signature and
#     an identity_regexp that does not pin one identity of the pin's repository;
#   - the DEBs the local APT bridge serves (releases newer than the pin) are
#     recorded as unsigned and the report says so (design 9).
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

command -v cosign >/dev/null || ds_fail "cosign is required by this test"
apply_world
fixtures=$(ds_fixture common/sigstore)
pin=agent_tools.example-release
workflow=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags
base=https://downloads.example.invalid/example-release
start=$(git -C "$inst" rev-parse HEAD)

serve() {
  mkdir -p "$FAKE_NIX_STATE/serve"
  cp -- "$2" "$FAKE_NIX_STATE/serve/$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
}
unserve() {
  rm -f "$FAKE_NIX_STATE/serve/$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
}
# release_row VERSION URL FILE [DIGEST_FILE]: a row that moves the pin to VERSION,
# FILE at URL; the row names the digest of DIGEST_FILE (default FILE).
release_row() {
  local named=${4:-$3}
  serve "$2" "$3"
  rows "$(row "$pin" github-release "$(json_get "$versions" ".agent_tools[\"example-release\"].minimum_version" | tr -d '"')" "$1" update \
    "$(jq -cn --arg tag "v$1" --arg url "$2" --arg sha "$(sha256sum "$named" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$named")" \
      '{tag: $tag, asset: ($url | split("/") | last), size: $size, sha256: $sha, url: $url}')")"
}
signature() {
  json_get "$versions" ".agent_tools[\"example-release\"].signature | $1"
}
at() {
  git -C "$inst" reset -q --hard "$1"
  rm -rf "$FAKE_NIX_STATE/serve" "$FAKE_NIX_STATE/unreachable"
}
commit() {
  git -C "$inst" add -A
  git -C "$inst" commit -q -m "$1"
  git -C "$inst" rev-parse HEAD
}
# archive OUT PATH=FILE...: a tar.gz holding each FILE at PATH, in order.
archive() {
  local out=$1 spec dir
  shift
  : >"$out.tar"
  rm -f "$out.tar"
  for spec in "$@"; do
    dir=$(mktemp -d "$DS_TEST_ROOT/entry.XXXXXX")
    mkdir -p "$dir/$(dirname "${spec%%=*}")"
    cp "${spec#*=}" "$dir/${spec%%=*}"
    chmod 0755 "$dir/${spec%%=*}"
    if [[ -e $out.tar ]]; then
      tar -rf "$out.tar" -C "$dir" "${spec%%=*}"
    else
      tar -cf "$out.tar" -C "$dir" "${spec%%=*}"
    fi
  done
  gzip -n -f "$out.tar"
  mv "$out.tar.gz" "$out"
}
ds_stub_override gh <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "attestation trusted-root") cat '$fixtures/trusted_root.json' ;;
  "api repos/"*"/attestations/sha256:"*)
    [[ ! -e '$DS_TEST_ROOT/api-down' ]] || { echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; }
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *) echo "gh stub: no canned response for: \$*" >&2; exit 1 ;;
esac
EOF
printf 'printf "example-release %%s\\n" 5.0.0; : >"$HOME/PWNED"\n' >"$DS_TEST_ROOT/evil"

# The component installs the archive member example-release-linux-x64.
json_edit "$manifest" '
data["components"].append({"name": "example-release", "method": "official-binary", "install": {
    "pin": "agent_tools.example-release", "member": "example-release-linux-x64", "verify": "sha256"}})
'
git -C "$inst" add -A
git -C "$inst" commit -q -m "the component of the release"
start=$(git -C "$inst" rev-parse HEAD)

# The honest history: 4.1.0 signed (the bundle is named after the member).
archive "$DS_TEST_ROOT/r41.tar.gz" "example-release-linux-x64=$fixtures/example-release-4.1.0"
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64.tar.gz" "$DS_TEST_ROOT/r41.tar.gz"
serve "$base/v4.1.0/example-release-linux-x64.sigstore.json" "$fixtures/example-release-4.1.0.sigstore.json"
assert_exit 0 apply --latest "$rows"
assert_eq '["member","example-release-linux-x64"]' "$(signature '[.subject, .member]')"
honest=$(commit "honest 4.1.0")

# --- The attacker's 5.0.0: the genuine signed 4.1.0 binary at another path, an
# evil binary at the installed member. -------------------------------------
v5=$base/v5.0.0/example-release-linux-x64.tar.gz
archive "$DS_TEST_ROOT/r50.tar.gz" "a/example-release-linux-x64=$fixtures/example-release-4.1.0" \
  "example-release-linux-x64=$DS_TEST_ROOT/evil"
release_row 5.0.0 "$v5" "$DS_TEST_ROOT/r50.tar.gz"
serve "$base/v5.0.0/example-release-linux-x64.sigstore.json" "$fixtures/example-release-4.1.0.sigstore.json"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-failed $pin" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
# The genuine 4.1.0 binary at the installed member: signed, but by v4.1.0.
archive "$DS_TEST_ROOT/r50.tar.gz" "example-release-linux-x64=$fixtures/example-release-4.1.0"
release_row 5.0.0 "$v5" "$DS_TEST_ROOT/r50.tar.gz"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-identity-version $pin" "$(item_codes)"
assert_eq "[\"$workflow/v4.1.0\",\"v5.0.0\"]" "$(jq -c '.items[0] | [.identity, .tag]' "$state/review.json")"
assert_eq "$before" "$(tree_state)"
# Two entries with the installed path: the signed one first, the evil one last.
archive "$DS_TEST_ROOT/r50.tar.gz" "example-release-linux-x64=$fixtures/example-release-5.0.0" \
  "example-release-linux-x64=$DS_TEST_ROOT/evil"
release_row 5.0.0 "$v5" "$DS_TEST_ROOT/r50.tar.gz"
serve "$base/v5.0.0/example-release-linux-x64.sigstore" "$fixtures/example-release-5.0.0.sigstore"
unserve "$base/v5.0.0/example-release-linux-x64.sigstore.json"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-failed $pin" "$(item_codes)"
assert_contains "$(jq -r '.items[0].error' "$state/review.json")" "holds example-release-linux-x64 more than once"
assert_eq "$before" "$(tree_state)"
# The archive the release serves is not the one the row's digest names.
archive "$DS_TEST_ROOT/r50.tar.gz" "example-release-linux-x64=$fixtures/example-release-5.0.0"
archive "$DS_TEST_ROOT/other.tar.gz" "example-release-linux-x64=$fixtures/example-release-5.0.0" "README=$DS_TEST_ROOT/evil"
release_row 5.0.0 "$v5" "$DS_TEST_ROOT/r50.tar.gz" "$DS_TEST_ROOT/other.tar.gz"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "$v5 does not have the digest of the pin"
assert_eq "$before" "$(tree_state)"
# The genuine 5.0.0 moves.
release_row 5.0.0 "$v5" "$DS_TEST_ROOT/r50.tar.gz"
assert_exit 0 apply --latest "$rows"
assert_eq "[\"member\",\"example-release-linux-x64\",\"$workflow/v5.0.0\"]" "$(signature '[.subject, .member, .identity]')"
assert_exit 0 pins check

# --- A plain asset: the signature of an older release replayed. ------------
at "$honest"
raw=$base/v5.0.0/example-release-linux-x64
release_row 5.0.0 "$raw" "$fixtures/example-release-4.1.0"
serve "$raw.sigstore.json" "$fixtures/example-release-4.1.0.sigstore.json"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-identity-version $pin" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# --- First use: a fork's workflow is not the signer of this repository. -----
at "$start"
release_row 5.0.0 "$raw" "$fixtures/example-release-5.0.0"
serve "$raw.sigstore.json" "$fixtures/example-release-5.0.0.fork.sigstore.json"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-first-use-foreign $pin" "$(item_codes)"
assert_eq "[\"https://github.com/example/example-fork/.github/workflows/release.yml@refs/tags/v5.0.0\",\"example/example-release\"]" \
  "$(jq -c '.items[0] | [.identity, .repository]' "$state/review.json")"
assert_eq "$before" "$(tree_state)"

# --- No answer from the network: no verdict, no review item. ---------------
at "$honest"
release_row 5.0.0 "$raw" "$fixtures/example-release-5.0.0"
mkdir -p "$FAKE_NIX_STATE"
printf '%s\n' "$raw.sigstore.json" "$raw.sigstore" "$raw.bundle" >"$FAKE_NIX_STATE/unreachable"
before=$(tree_state)
assert_exit 6 apply --latest "$rows"
assert_eq "" "$(item_codes)"
assert_contains "$DS_STDOUT" "download:$pin: signature discovery got no answer"
assert_eq "$before" "$(tree_state)"
# A server error of the attestation API is no answer either.
rm -f "$FAKE_NIX_STATE/unreachable"
: >"$DS_TEST_ROOT/api-down"
assert_exit 6 apply --latest "$rows"
assert_eq "" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
# An unsigned source moves without the answer, and says what it lacks.
at "$start"
: >"$DS_TEST_ROOT/api-down"
release_row 5.0.0 "$raw" "$fixtures/example-release-5.0.0"
printf '%s\n' "$raw.sigstore.json" >"$FAKE_NIX_STATE/unreachable"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved agent_tools.example-release: 4.0.0 -> 5.0.0 (unsigned, signature discovery incomplete)"
rm -f "$DS_TEST_ROOT/api-down"

# --- pins check: a signed source without its signature, a loose signer. ----
at "$honest"
assert_exit 0 pins check
json_edit "$versions" 'del data["agent_tools"]["example-release"]["signature"]'
assert_exit 1 pins check
assert_contains "$DS_STDERR" "trust.signers.agent_tools.example-release: a signed source, and agent_tools.example-release records no signature"
at "$honest"
for loose in '.*' 'github\.com/example/' '^https://github\.com/example/(example-release|example-fork)/.+$' \
  '^https://github\.com/example/example-fork/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'; do
  json_edit "$versions" 'data["trust"]["signers"]["agent_tools.example-release"]["identity_regexp"] = r"'"$loose"'"'
  assert_exit 1 pins check
  assert_contains "$DS_STDERR" "trust.signers.agent_tools.example-release: the identity_regexp does not pin one identity of example/example-release"
  at "$honest"
done

# --- The local APT bridge: later releases are unsigned, and the lock says so.
at "$start"
json_edit "$manifest" '
data["components"].append({"name": "example-desktop", "method": "deb", "install": {
    "pin": "desktop_packages.example-desktop", "packageNames": ["example-desktop"],
    "githubRelease": {"repository": "example-org/example-desktop", "assets": {"amd64": "example-desktop_{version}_amd64.deb"}}}})
'
desktop=https://downloads.example.invalid/example-desktop_1.6.0_amd64.deb
rows "$(row desktop_packages.example-desktop github-release 1.5.0 1.6.0 update '{"tag":"v1.6.0","asset":"example-desktop_1.6.0_amd64.deb","size":300,"sha256":"'"$(printf '%064d' 7)"'","url":"'"$desktop"'"}')"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved desktop_packages.example-desktop: 1.5.0 -> 1.6.0 (unsigned; the local APT bridge serves later releases of example-org/example-desktop unsigned)"
assert_eq "{\"kind\":\"unsigned\",\"repository\":\"example-org/example-desktop\",\"first_seen\":\"$(date -u +%Y-%m-%d)\"}" \
  "$(json_get "$versions" '.trust.apt_bridge["desktop_packages.example-desktop"]')"
assert_exit 0 pins check
