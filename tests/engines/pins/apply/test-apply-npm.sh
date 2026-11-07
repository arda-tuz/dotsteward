# shellcheck shell=bash
# npm rows of a bundle move together: package.json, a regenerated package-lock,
# an audit, the lock mirrors and the bundle hash. A pin outside a bundle with
# *_nix_sha256 fields gets its hashes from fake-hash builds.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
bundle=$inst/packages/example-bundle
head=$(printf 'c%.0s' {1..40})

rows \
  "$(row npm.example-cli npm 2.0.0 2.1.0 update '{"git_head":"'"$head"'","node_engine":">=20"}')" \
  "$(row npm_security_overrides.example-dep npm 1.0.1 1.0.2 update '{"git_head":null}')"
old_hash=$(json_get "$versions" '.agent_tools.npm_bundle_nix_sha256')
assert_exit 0 apply --latest "$rows"

assert_eq '{"example-cli":"2.1.0"}' "$(json_get "$bundle/package.json" .dependencies)"
assert_eq '{"example-cli":{"example-dep":"1.0.2"}}' "$(json_get "$bundle/package.json" .overrides)"
assert_eq '"2.1.0"' "$(json_get "$bundle/package-lock.json" '.packages["node_modules/example-cli"].version')"
assert_eq '["2.1.0"]' "$(json_get "$skills" '[.npm_tools["example-cli"]]')"
assert_eq "[\"2.1.0\",\"$head\"]" "$(json_get "$versions" '.agent_tools["example-cli"] | [.version, .source_revision]')"
assert_eq '"1.0.2"' "$(json_get "$versions" '.agent_tools.npm_security_overrides["example-dep"].version')"
new_hash=$(json_get "$versions" '.agent_tools.npm_bundle_nix_sha256')
assert_eq "\"$(fake_hash "example-bundle.npmDeps:$(<"$bundle/package-lock.json")"$'\n'"")\"" "$new_hash"
[[ $new_hash != "$old_hash" ]] || ds_fail "the bundle hash did not change"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "nixpkgs#nodejs"
assert_exit 0 pins check

# Findings that grow wait for a decision: the whole bundle is restored, and the other
# groups still move.
git -C "$inst" add -A
git -C "$inst" commit -q -m "first bundle move"
before_package=$(sha256sum "$bundle/package.json" "$bundle/package-lock.json")
printf '1 2' >"$FAKE_NIX_STATE/audit-counts"
digest=$(printf '%064d' 7)
rows \
  "$(row npm.example-cli npm 2.1.0 2.2.0 update '{"git_head":"'"$head"'"}')" \
  "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","size":1,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')"
assert_exit 3 apply --latest "$rows"
assert_eq "npm-audit npm.example-cli" "$(item_codes)"
assert_contains "$(jq -c '.items[0].reason' "$state/review.json")" "2 findings, 1 before"
assert_eq "$before_package" "$(sha256sum "$bundle/package.json" "$bundle/package-lock.json")"
assert_eq '"2.1.0"' "$(json_get "$versions" '.agent_tools["example-cli"].version')"
assert_eq '"4.1.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
assert_eq '[["download:agent_tools.example-release","ok"],["npm:packages/example-bundle","ok"]]' \
  "$(last_report '[.steps[] | select(.name | test(":")) | [.name, .status]] | sort')"
assert_exit 0 pins check

# An audit that gives no answer is no permission either.
git -C "$inst" add -A
git -C "$inst" commit -q -m "release move"
rows "$(row npm.example-cli npm 2.1.0 2.2.0 update '{"git_head":"'"$head"'"}')"
printf '0 word' >"$FAKE_NIX_STATE/audit-counts"
assert_exit 3 apply --latest "$rows"
assert_eq "npm-audit npm.example-cli" "$(item_codes)"
assert_eq '"2.1.0"' "$(json_get "$versions" '.agent_tools["example-cli"].version')"

# Findings that do not grow move the bundle, even when some stay: they stand in the report, and
# nothing waits. The audit keeps its own contract: moving cannot make it worse.
printf '11 10' >"$FAKE_NIX_STATE/audit-counts"
assert_exit 0 apply --latest "$rows"
assert_eq '"2.2.0"' "$(json_get "$versions" '.agent_tools["example-cli"].version')"
assert_eq "npm-audit-remaining" "$(jq -r '.items[0].code' "$state/review.json")"
assert_eq "10" "$(jq -r '.items[0].findings' "$state/review.json")"
assert_exit 0 pins check
rm -f -- "$FAKE_NIX_STATE/audit-counts"

# A new major of a security override is a review item.
git -C "$inst" add -A
git -C "$inst" commit -q -m "bundle move with findings"
before=$(tree_state)
rows "$(row npm_security_overrides.example-dep npm 1.0.2 2.0.0 review '{"git_head":null}')"
assert_exit 3 apply --latest "$rows"
assert_eq "pins-constrained npm_security_overrides.example-dep" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# A build pin outside a bundle: version, tag, commit of the tag and new hash.
app=$github/example/example-app
old_hash=$(json_get "$versions" '.agent_tools["example-app"].source_nix_sha256')
rows "$(row agent_tools.example-app npm 3.1.0 3.2.0 update '{"git_head":null,"integrity":"sha512-abc"}')"
assert_exit 0 apply --latest "$rows"
commit=$(git -C "$app" rev-parse 'refs/tags/v3.2.0^{commit}')
assert_eq "[\"3.2.0\",\"v3.2.0\",\"$commit\",\"https://registry.example.invalid/example-app/-/example-app-3.2.0.tgz\",\"$(fake_hash "example-app.src:3.2.0")\"]" \
  "$(json_get "$versions" '.agent_tools["example-app"] | [.version, .official_tag, .tag_revision, .model_data_url, .source_nix_sha256]')"
assert_exit 0 pins check

# A builder that fails for another reason than the hash: restored, no placeholder
# stays behind.
before=$(tree_state)
printf 'src\n' >"$FAKE_NIX_STATE/fail-build"
_apply_tag_app() {
  ds_git_commit "$sources/example/example-app" VERSION v3.3.0 "chore: v3.3.0"
  git -C "$sources/example/example-app" tag -a v3.3.0 -m "release"
  _apply_publish example/example-app
}
_apply_tag_app
rows "$(row agent_tools.example-app npm 3.2.0 3.3.0 update '{"git_head":null}')"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "builder for"
assert_eq "$before" "$(tree_state)"
