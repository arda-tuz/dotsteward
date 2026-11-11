# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The authenticity of a pypi pin the writer moves with its hash-pinned requirements (T17-a,
# PEP 740): every file the regenerated requirements allow for the pinned distribution (each
# --hash of its line, found by its digest among the files of the release on the index) is
# looked up in the integrity API of the index, each lookup bounded by a timeout. A release
# without provenance moves and the source is recorded unsigned. A release whose every file has
# a publish attestation is verified with cosign against the trusted root: the first signer,
# which must be a workflow of the declared repository, is trusted on first use, and the pin
# records the identity and the files it vouches for. A signed source whose file lacks an
# attestation, an attestation of another file, a lookup without an answer: the pin stays (a
# review item, or the group waits for the next run), and the requirements are put back.
# The transitive requirements stay hash-pinned only.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

command -v cosign >/dev/null || ds_fail "cosign is required by this test"
apply_world
fixtures=$(ds_fixture common/sigstore)
pin=pypi.example-tool
requirements=$inst/components/example-tool/requirements.txt
issuer=https://token.actions.githubusercontent.com
workflow=https://github.com/example/example-tool/.github/workflows/release.yml@refs/tags
regexp='^https://github\.com/example/example-tool/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
publish=https://docs.pypi.org/attestations/publish/v1
today=$(date -u +%Y-%m-%d)
wheel=example_tool-1.1.0-py3-none-any.whl
sdist=example_tool-1.1.0.tar.gz

www=$DS_TEST_ROOT/www
mkdir -p "$www/pypi/example-tool/1.1.0" "$www/integrity/example-tool/1.1.0"
ds_httpfix_start "$www"
url=$DS_HTTPFIX_URL

# The release on the index: both files, with their digests.
jq --arg base "$url/files" '{info: {name: "example-tool", version: "1.1.0"},
  urls: [to_entries[] | {filename: .key, digests: {sha256: .value}, url: "\($base)/\(.key)", yanked: false}]}' \
  "$fixtures/example-tool-1.1.0.files.json" >"$www/pypi/example-tool/1.1.0/json"
digest() {
  jq -r --arg name "$1" '.[$name]' "$fixtures/example-tool-1.1.0.files.json"
}
# The compiler pins both files.
mkdir -p "$FAKE_NIX_STATE/hashes"
printf '%s\n%s\n' "$(digest "$wheel")" "$(digest "$sdist")" >"$FAKE_NIX_STATE/hashes/example-tool==1.1.0"

# provenance FILE [FIXTURE]: the integrity API answers FIXTURE for FILE (none: 404).
provenance() {
  local target=$www/integrity/example-tool/1.1.0/$1/provenance
  if (($# == 1)); then
    rm -rf -- "${target%/*}"
  else
    mkdir -p "${target%/*}"
    cp -- "$fixtures/$2" "$target"
  fi
}
# declare_row [JSON]: the declaration of the pypi row, its index on the loopback server.
declare_row() {
  DECLARED=${1:-"{}"} json_edit "$manifest" '
import json, os
for entry in data["pins"]["latest"]:
    if entry["id"] == "pypi.example-tool":
        entry.clear()
        entry.update({"component": "example-tool", "id": "pypi.example-tool", "adapter": "pypi",
                      "package": "example-tool", "index": "'"$url/pypi"'", "repo": "example/example-tool"})
        entry.update(json.loads(os.environ["DECLARED"]))
'
}
signer() {
  json_get "$versions" ".trust.signers[\"$pin\"] | $1"
}
signature() {
  json_get "$versions" ".pypi[\"example-tool\"].signature | $1"
}
commit() {
  git -C "$inst" add -A
  git -C "$inst" commit -q -m "$1"
  git -C "$inst" rev-parse HEAD
}
at() {
  git -C "$inst" reset -q --hard "$1"
}

declare_row
json_edit "$versions" 'data.setdefault("trust", {})["sigstore_root"] = __import__("json").load(open("'"$fixtures/trusted_root.json"'"))'
start=$(commit "the pypi row reads the loopback index")
rows "$(row "$pin" pypi 1.0.0 1.1.0 update)"

# --- No provenance: moves, the source is recorded unsigned. --------------------------------
assert_exit 0 apply --latest "$rows" --json
assert_eq '[{"id":"pypi.example-tool","authenticity":"unsigned"}]' "$(jq -c '[.moved[] | {id, authenticity}]' <<<"$DS_STDOUT")"
assert_eq '{"kind":"unsigned","first_seen":"'"$today"'"}' "$(signer .)"
assert_eq null "$(signature .)"
assert_eq '"1.1.0"' "$(json_get "$versions" '.pypi["example-tool"].version')"
assert_contains "$(<"$requirements")" "--hash=sha256:$(digest "$wheel")"
assert_contains "$(<"$DS_HTTPFIX_LOG")" "GET /pypi/example-tool/1.1.0/json"
assert_contains "$(<"$DS_HTTPFIX_LOG")" "GET /integrity/example-tool/1.1.0/$wheel/provenance"
assert_contains "$(<"$DS_HTTPFIX_LOG")" "GET /integrity/example-tool/1.1.0/$sdist/provenance"
assert_exit 0 pins check
at "$start"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved pypi.example-tool: 1.0.0 -> 1.1.0 (unsigned)"
at "$start"

# --- Only some files attested: not signed, so unsigned, and it says so. --------------------
provenance "$wheel" "$wheel.provenance.json"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved pypi.example-tool: 1.0.0 -> 1.1.0 (unsigned, 1 of 2 files attested)"
assert_eq '"unsigned"' "$(signer .kind)"
at "$start"

# --- First use: every file attested by the declared repository. ----------------------------
provenance "$sdist" "$sdist.provenance.json"
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved pypi.example-tool: 1.0.0 -> 1.1.0 (sigstore: $workflow/v1.1.0, trusted on first use)"
assert_eq "$(jq -c --arg r "$regexp" --arg i "$issuer" --arg d "$today" -n '{kind: "sigstore", identity_regexp: $r, issuer: $i, first_seen: $d}')" "$(signer .)"
assert_eq "$(jq -c --arg id "$workflow/v1.1.0" --arg p "$publish" --slurpfile files "$fixtures/example-tool-1.1.0.files.json" -n \
  '{kind: "attestation", subject: "distributions", predicate_type: $p, identity: $id, files: $files[0]}')" "$(signature .)"
assert_eq '[{"id":"pypi.example-tool","status":"sigstore","identity":"'"$workflow/v1.1.0"'","first_use":true}]' \
  "$(last_report '[.steps[] | select(.moved) | .authenticity[]]')"
assert_exit 0 pins check

# --- A pinned signer: the next move verifies against it. -----------------------------------
at "$start"
json_edit "$versions" '
data["trust"]["signers"] = {"pypi.example-tool": {"kind": "sigstore", "identity_regexp": r"'"$regexp"'",
  "issuer": "'"$issuer"'", "first_seen": "2026-01-01"}}'
pinned=$(commit "the source is signed")
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved pypi.example-tool: 1.0.0 -> 1.1.0 (sigstore: $workflow/v1.1.0)"
assert_eq '"2026-01-01"' "$(signer .first_seen)"

# A file of a signed source without an attestation: the pin and the requirements stay.
at "$pinned"
provenance "$sdist"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-signature-missing pypi.example-tool" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# An attestation of another file at the address of this one does not verify.
provenance "$sdist" "$wheel.provenance.json"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-failed pypi.example-tool" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# Another signer than the pinned one.
provenance "$sdist" "$sdist.provenance.json"
provenance "$wheel" "$wheel.fork.provenance.json"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-signer-changed pypi.example-tool" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# The integrity API gives no answer: a signed source waits for the next run, no review item.
provenance "$wheel" "$wheel.provenance.json"
declare_row '{"integrity": "http://127.0.0.1:9/integrity"}'
git -C "$inst" add -A
git -C "$inst" commit -q -m "the integrity API is down"
before=$(tree_state)
assert_exit 6 apply --latest "$rows"
assert_contains "$DS_STDOUT$DS_STDERR" "signature discovery got no answer"
assert_eq "$before" "$(tree_state)"
assert_eq '"1.0.0"' "$(json_get "$versions" '.pypi["example-tool"].version')"

# --- First use by a workflow of another repository: nothing is pinned. ---------------------
at "$start"
provenance "$wheel" "$wheel.fork.provenance.json"
before=$(tree_state)
rm -f -- "$state/review.json"
assert_exit 3 apply --latest "$rows"
assert_eq "authenticity-first-use-foreign pypi.example-tool" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# An unsigned source moves when the integrity API gives no answer, labelled so.
declare_row '{"integrity": "http://127.0.0.1:9/integrity"}'
commit "the integrity API is down" >/dev/null
assert_exit 0 apply --latest "$rows"
assert_contains "$DS_STDOUT" "moved pypi.example-tool: 1.0.0 -> 1.1.0 (unsigned, signature discovery incomplete)"
