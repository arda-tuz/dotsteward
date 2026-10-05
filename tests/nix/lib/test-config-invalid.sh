# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# lib/config.nix: every invalid fixture (fixtures/invalid/*.toml) yields
# exactly the messages listed in its "# expect:" lines, in order, and
# loading it throws them with the "dotsteward: workstation.toml: " prefix.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

dir=$nix_lib_fixtures/invalid
cases=()
for file in "$dir"/*.toml; do
  cases+=("$(basename "$file" .toml)")
done
((${#cases[@]} >= 15)) || ds_fail "expected the invalid fixtures, found ${#cases[@]}"

# One evaluation for all cases: name -> list of messages.
actual_all=$(nix_lib_json "lib.mapAttrs (name: _: errorsOfToml (fixtures + \"/invalid/\${name}\"))
  (lib.filterAttrs (name: _: lib.hasSuffix \".toml\" name) (builtins.readDir (fixtures + \"/invalid\")))")

for name in "${cases[@]}"; do
  expected=$(sed -n 's/^# expect: //p' "$dir/$name.toml" | jq -R . | jq -cs .)
  [[ $expected != '[]' ]] || ds_fail "$name.toml has no expect line"
  actual=$(jq -c --arg n "$name.toml" '.[$n]' <<<"$actual_all")
  assert_eq "$expected" "$actual" "errors of invalid/$name.toml"
done

# Loading throws every message, each line with the prefix.
assert_nix_fails "loadFixture \"invalid/wrong-type\"" \
  "error: dotsteward: workstation.toml: gate.nix_max_jobs: expected an integer, got a float" \
  "dotsteward: workstation.toml: nix.allow_unfree: expected a boolean, got a string" \
  "dotsteward: workstation.toml: upstream: expected a table, got a string"
assert_nix_fails "loadFixture \"invalid/unknown-nested-key\"" \
  "error: dotsteward: workstation.toml: unknown key nix.allow_unfre"
assert_nix_fails "loadFixture \"invalid/schema-version-2\"" \
  "error: dotsteward: workstation.toml: schema_version 2 is not supported"
assert_not_contains "$DS_STDERR" "unknown key future" "a future schema reports only its version"
assert_nix_fails "loadFixture \"invalid/profile-roles\"" \
  "error: dotsteward: workstation.toml: profiles.default: \"other\" is not in profiles.names"

# A TOML syntax error surfaces from the parser.
file=$(toml_fixture broken 'schema_version = = 1')
assert_nix_fails "loadToml \"$file\"" "error"
