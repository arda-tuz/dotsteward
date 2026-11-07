# shellcheck shell=bash
# Authenticity of a download pin the writer moves (design 9, T8-a): the
# writer looks for a sigstore bundle published next to the new file (named
# after the file or, for an archive, after its member) and for a GitHub
# artifact attestation of its digest, each lookup bounded by a timeout, and
# verifies what it finds with cosign against the trusted root (offline, from
# the recorded bundle). The first verified signer is trusted on first use:
# the lock records its identity as a regular expression (the tag generalized)
# and its OIDC issuer; a later signer that does not match, a signature that
# does not verify and a signed source that stops signing are review items, and
# the pin stays. The pin records the bundle it was verified with (a legacy
# cosign bundle converted to a Sigstore bundle), so an install verifies it
# again offline. A source without any signature moves (no minimum age, T8-a)
# and is labelled unsigned in the report.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

command -v cosign >/dev/null || ds_fail "cosign is required by this test"
apply_world
fixtures=$(ds_fixture common/sigstore)
pin=agent_tools.example-release
issuer=https://token.actions.githubusercontent.com
workflow=https://github.com/example/example-release/.github/workflows/release.yml@refs/tags
regexp='^https://github\.com/example/example-release/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
today=$(date -u +%Y-%m-%d)
base=https://downloads.example.invalid/example-release
start=$(git -C "$inst" rev-parse HEAD)

# serve URL FILE: the fake nix downloads FILE at URL.
serve() {
  mkdir -p "$FAKE_NIX_STATE/serve"
  cp -- "$2" "$FAKE_NIX_STATE/serve/$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
}
# release_row VERSION URL FILE: a row that moves the pin to VERSION, FILE at URL.
release_row() {
  serve "$2" "$3"
  rows "$(row "$pin" github-release "$(json_get "$versions" ".agent_tools[\"example-release\"].minimum_version" | tr -d '"')" "$1" update \
    "$(jq -cn --arg tag "v$1" --arg url "$2" --arg sha "$(sha256sum "$3" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$3")" \
      '{tag: $tag, asset: ($url | split("/") | last), size: $size, sha256: $sha, url: $url}')")"
}
signature() {
  json_get "$versions" ".agent_tools[\"example-release\"].signature | $1"
}
signer() {
  json_get "$versions" ".trust.signers[\"$pin\"] | $1"
}
at() {
  git -C "$inst" reset -q --hard "$1"
}
commit() {
  git -C "$inst" add -A
  git -C "$inst" commit -q -m "$1"
  git -C "$inst" rev-parse HEAD
}

# The GitHub CLI: no attestation unless the scenario names a digest, and the
# trusted root of the fixtures.
attested=$DS_TEST_ROOT/attested
: >"$attested"
ds_stub_override gh <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "attestation trusted-root")
    [[ ! -e '$DS_TEST_ROOT/no-root' ]] || { echo "error: tuf: network is unreachable" >&2; exit 1; }
    cat '$fixtures/trusted_root.json' ;;
  "api repos/example/example-release/attestations/sha256:"*)
    args=\$*
    digest=\${args##*sha256:}
    grep -qx "\$digest" '$attested' || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    printf '{"attestations": [{"bundle": null, "bundle_url": "https://example.invalid/bundle.json.sn"}]}\n' ;;
  "attestation download "*" --repo example/example-release")
    digest=\$(sha256sum "\$3" | cut -d' ' -f1)
    cp '$fixtures/example-release-5.0.0.intoto.jsonl' "sha256:\$digest.jsonl" ;;
  *) echo "gh stub: no canned response for: \$*" >&2; exit 1 ;;
esac
EOF

# --- Unsigned: moves, labelled, and the source is recorded as unsigned. ------
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64" "$fixtures/example-release-4.1.0"
assert_exit 0 apply --latest "$rows" --json
assert_eq '[{"id":"agent_tools.example-release","authenticity":"unsigned"}]' "$(jq -c '[.moved[] | {id, authenticity}]' <<<"$DS_STDOUT")"
assert_eq '{"kind":"unsigned","first_seen":"'"$today"'"}' "$(signer .)"
assert_eq null "$(signature .)"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "store prefetch-file --json $base/v4.1.0/example-release-linux-x64.sigstore.json"
assert_exit 0 pins check
at "$start"
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64" "$fixtures/example-release-4.1.0"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved agent_tools.example-release: 4.0.0 -> 4.1.0 (unsigned)"
at "$start"
# A server that answers every path (an HTML page, a JSON document that is no
# bundle) publishes no signature: the source is still unsigned.
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64" "$fixtures/example-release-4.1.0"
printf '<!doctype html><title>Not here</title>\n' >"$DS_TEST_ROOT/page.html"
printf '{"error": "not found"}\n' >"$DS_TEST_ROOT/answer.json"
serve "$base/v4.1.0/example-release-linux-x64.sigstore.json" "$DS_TEST_ROOT/answer.json"
serve "$base/v4.1.0/example-release-linux-x64.sigstore" "$DS_TEST_ROOT/page.html"
serve "$base/v4.1.0/example-release-linux-x64.bundle" "$DS_TEST_ROOT/page.html"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved agent_tools.example-release: 4.0.0 -> 4.1.0 (unsigned)"
rm -f "$FAKE_NIX_STATE/serve/"*
at "$start"

# --- First use: a bundle of the asset; the signer is pinned. ---------------
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64" "$fixtures/example-release-4.1.0"
serve "$base/v4.1.0/example-release-linux-x64.sigstore.json" "$fixtures/example-release-4.1.0.sigstore.json"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved agent_tools.example-release: 4.0.0 -> 4.1.0 (sigstore: $workflow/v4.1.0, trusted on first use)"
assert_eq "[\"message\",\"asset\",\"$workflow/v4.1.0\"]" "$(signature '[.kind, .subject, .identity]')"
assert_eq "$(jq -c . "$fixtures/example-release-4.1.0.sigstore.json")" "$(signature '.bundle')"
assert_eq "$(jq -c --arg r "$regexp" --arg i "$issuer" --arg d "$today" -n '{kind: "sigstore", identity_regexp: $r, issuer: $i, first_seen: $d}')" "$(signer .)"
assert_eq "$(jq -c . "$fixtures/trusted_root.json")" "$(json_get "$versions" .trust.sigstore_root)"
assert_eq '[{"id":"agent_tools.example-release","status":"sigstore","identity":"'"$workflow/v4.1.0"'","first_use":true}]' \
  "$(last_report '[.steps[] | select(.moved) | .authenticity[]]')"
assert_exit 0 pins check
signed=$(commit "the release is signed")
# pins check refuses a recorded signature the install could not verify.
json_edit "$versions" 'del data["trust"]["signers"]["agent_tools.example-release"]'
assert_exit 1 pins check
assert_contains "$DS_STDERR" "trust.signers.agent_tools.example-release: a recorded signature needs a sigstore signer with identity_regexp and issuer"
at "$signed"

# --- The same signer, a legacy cosign bundle: converted and recorded. -------
url=$base/v5.0.0/example-release-linux-x64
release_row 5.0.0 "$url" "$fixtures/example-release-5.0.0"
serve "$url.sigstore" "$fixtures/example-release-5.0.0.sigstore"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved agent_tools.example-release: 4.1.0 -> 5.0.0 (sigstore: $workflow/v5.0.0)"
assert_eq "[\"message\",\"asset\",\"$workflow/v5.0.0\",\"application/vnd.dev.sigstore.bundle+json;version=0.1\"]" \
  "$(signature '[.kind, .subject, .identity, .bundle.mediaType]')"
assert_eq "$(jq -c .base64Signature "$fixtures/example-release-5.0.0.sigstore")" "$(signature .bundle.messageSignature.signature)"
assert_eq "\"$today\"" "$(signer .first_seen)"
# What the install verifies later, offline: the recorded bundle and root.
json_get "$versions" '.agent_tools["example-release"].signature.bundle' >"$DS_TEST_ROOT/recorded.json"
json_get "$versions" .trust.sigstore_root >"$DS_TEST_ROOT/root.json"
assert_exit 0 cosign verify-blob --trusted-root "$DS_TEST_ROOT/root.json" --bundle "$DS_TEST_ROOT/recorded.json" \
  --certificate-identity-regexp "$regexp" --certificate-oidc-issuer "$issuer" "$fixtures/example-release-5.0.0"
assert_exit 0 pins check

# --- Another signer: a review item, the pin stays. --------------------------
at "$signed"
release_row 5.0.0 "$url" "$fixtures/example-release-5.0.0"
serve "$url.sigstore.json" "$fixtures/example-release-5.0.0.fork.sigstore.json"
rm -f "$FAKE_NIX_STATE/serve/$(printf '%s' "$url.sigstore" | sha256sum | cut -d' ' -f1)"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-signer-changed $pin" "$(item_codes)"
assert_eq "https://github.com/example/example-fork/.github/workflows/release.yml@refs/tags/v5.0.0
$regexp" "$(jq -r '.items[0] | .identity, .identity_regexp' "$state/review.json")"
assert_eq "$before" "$(tree_state)"

# --- A signed source that stops signing: a review item, the pin stays. ------
rm -f "$FAKE_NIX_STATE/serve/$(printf '%s' "$url.sigstore.json" | sha256sum | cut -d' ' -f1)"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-signature-missing $pin" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# --- A GitHub artifact attestation of the digest (build provenance). --------
sha256sum "$fixtures/example-release-5.0.0" | cut -d' ' -f1 >"$attested"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved agent_tools.example-release: 4.1.0 -> 5.0.0 (sigstore: $workflow/v5.0.0)"
assert_eq "[\"attestation\",\"asset\",\"https://slsa.dev/provenance/v1\",\"$workflow/v5.0.0\"]" \
  "$(signature '[.kind, .subject, .predicate_type, .identity]')"
assert_eq "$(jq -c . "$fixtures/example-release-5.0.0.intoto.jsonl")" "$(signature .bundle)"
assert_contains "$(ds_calls_of gh)" "gh api repos/example/example-release/attestations/sha256:$(<"$attested")"
assert_exit 0 pins check
: >"$attested"

# --- A signature that does not verify (a certificate authority the root does
# not name), on first use: a review item, the pin stays. --------------------
at "$start"
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64" "$fixtures/example-release-4.1.0"
serve "$base/v4.1.0/example-release-linux-x64.sigstore.json" "$fixtures/example-release-4.1.0.foreign.sigstore.json"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-failed $pin" "$(item_codes)"
assert_contains "$(jq -r '.items[0].error' "$state/review.json")" "certificate"
assert_eq "$before" "$(tree_state)"

# --- No trusted root (none recorded, none readable): a review item. ----------
serve "$base/v4.1.0/example-release-linux-x64.sigstore.json" "$fixtures/example-release-4.1.0.sigstore.json"
: >"$DS_TEST_ROOT/no-root"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-no-trusted-root $pin" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
rm -f "$DS_TEST_ROOT/no-root"

# --- An archive whose member is signed (the bundle is named after the member).
archive=$DS_TEST_ROOT/archive
mkdir -p "$archive"
cp "$fixtures/example-release-4.1.0" "$archive/example-release-linux-x64"
tar -czf "$DS_TEST_ROOT/example-release-linux-x64.tar.gz" -C "$archive" example-release-linux-x64
rm -f "$FAKE_NIX_STATE/serve/$(printf '%s' "$base/v4.1.0/example-release-linux-x64.sigstore.json" | sha256sum | cut -d' ' -f1)"
release_row 4.1.0 "$base/v4.1.0/example-release-linux-x64.tar.gz" "$DS_TEST_ROOT/example-release-linux-x64.tar.gz"
serve "$base/v4.1.0/example-release-linux-x64.sigstore.json" "$fixtures/example-release-4.1.0.sigstore.json"
assert_exit 0 apply --latest "$rows"
assert_eq "[\"message\",\"member\",\"example-release-linux-x64\",\"$workflow/v4.1.0\"]" \
  "$(signature '[.kind, .subject, .member, .identity]')"
assert_exit 0 pins check
