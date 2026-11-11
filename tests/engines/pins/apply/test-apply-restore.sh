# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `pins apply --restore FILE` puts pins back to what an earlier commit held, through the groups of
# the writer, without the network: the whole group comes back from that commit, as it was (a
# download pin with its URL, size, digest and signature; the hash-pinned requirements of a pypi
# group with every pin they guard), the mirrors follow and `pins check` passes. A restored pin
# never takes the row of `pins latest` that would move it again. The signer stays as the lock
# records it: an entry without a signature does not come back for a signed source. A pin the
# writer has no group for (a flake input, an npm or a skill lock) is never restored and says so.
# --skip leaves a restore group alone, as it does a row.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
requirements=$inst/components/example-tool/requirements.txt
digest=$(printf '%064d' 7)
x=$(git -C "$inst" rev-parse HEAD)
release_entry() {
  json_get "$versions" '.agent_tools["example-release"]'
}
before_release=$(release_entry)
before_requirements=$(<"$requirements")

# Y: both pins move, as a producer moves them.
rows "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')" \
  "$(row pypi.example-tool pypi 1.0.0 1.1.0 update)"
assert_exit 0 apply --latest "$rows"
git -C "$inst" add -A
git -C "$inst" commit -q -m "chore: update pinned tool versions"
y=$(git -C "$inst" rev-parse HEAD)
assert_contains "$(<"$requirements")" "example-tool==1.1.0"

# restore ID...: the restore file that puts each ID back to what X held.
restore() {
  jq -n --arg commit "$x" '{schema_version: 1, pins: [$ARGS.positional[] | {id: ., commit: $commit}]}' \
    --args "$@" >"$DS_TEST_ROOT/restore.json"
}

# Back from X: the download pin as it was, the requirements as they were; upstream still calls
# the red versions the latest, and the rows do not move them again.
restore agent_tools.example-release pypi.example-tool
: >"$FAKE_NIX_STATE/calls"
assert_exit 0 apply --latest "$rows" --restore "$DS_TEST_ROOT/restore.json" --json
assert_eq '[{"id":"agent_tools.example-release","from":"4.1.0","to":"4.0.0","group":"restore:agent_tools.example-release"},{"id":"pypi.example-tool","from":"1.1.0","to":"1.0.0","group":"restore:components/example-tool/requirements.txt"}]' \
  "$(jq -c '[.moved[] | {id, from, to, group}]' <<<"$DS_STDOUT")"
assert_eq "$before_release" "$(release_entry)"
assert_eq "$before_requirements" "$(<"$requirements")"
assert_eq '"1.0.0"' "$(json_get "$versions" '.pypi["example-tool"].version')"
assert_eq '["4.0.0",1234]' "$(json_get "$skills" '.release_tools["example-release"] | [.version, .size]')"
assert_eq 0 "$(grep -c 'nixpkgs#example-compiler' "$FAKE_NIX_STATE/calls" || true)" "the requirements were not compiled again"
assert_exit 0 pins check
git -C "$inst" reset -q --hard "$y"

# --skip leaves a restore group alone.
restore agent_tools.example-release pypi.example-tool
assert_exit 0 apply --latest "$rows" --restore "$DS_TEST_ROOT/restore.json" --skip 'pypi.*' --json
assert_eq '["agent_tools.example-release"]' "$(jq -c '[.moved[].id]' <<<"$DS_STDOUT")"
assert_contains "$(<"$requirements")" "example-tool==1.1.0"
git -C "$inst" reset -q --hard "$y"

# A signed source never comes back without a signature: the entry of X has none.
json_edit "$versions" '
data.setdefault("trust", {}).setdefault("signers", {})["agent_tools.example-release"] = {
  "kind": "sigstore", "identity_regexp": "^https://github\\.com/example/example-release/\\.github/workflows/release\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$",
  "issuer": "https://token.actions.githubusercontent.com", "first_seen": "2026-11-01"}'
git -C "$inst" commit -q -am "the source is signed now"
before=$(tree_state)
restore agent_tools.example-release
assert_exit 3 apply --latest "$rows" --restore "$DS_TEST_ROOT/restore.json"
assert_eq "restore-unsigned agent_tools.example-release" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
git -C "$inst" reset -q --hard "$y"

# A pin without a group of the writer is never restored, and says so.
restore flake_inputs.example-term
before=$(tree_state)
assert_exit 3 apply --latest "$rows" --restore "$DS_TEST_ROOT/restore.json"
assert_eq "restore-unsupported flake_inputs.example-term" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
