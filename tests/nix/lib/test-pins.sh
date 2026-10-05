# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# lib/pins.nix: pinAt PINS PATH COMPONENT reads a versions.lock.json value
# by its dotted path and names the component when the key is missing.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

lock='(builtins.fromJSON (builtins.readFile (fixtures + "/versions.lock.json")))'

assert_nix_eq '"1.2.3"' "dsLib.pinAt $lock \"nix_packages.example-term.expected\" \"example-term\""
assert_nix_eq '{"version":"4.5.6","package":"example-app"}' "dsLib.pinAt $lock \"agent_tools.example-app\" \"example-app\"" "a table"
assert_nix_eq '"1.0"' "dsLib.pinAt $lock \"schema_version\" \"core\"" "a top-level key"
assert_nix_eq 'null' "dsLib.pinAt $lock \"nix_packages.example-term.notes\" \"example-term\"" "a present null"

# Missing leaf, missing section and a scalar where a table is expected.
assert_nix_fails "dsLib.pinAt $lock \"nix_packages.starship.expected\" \"shell\"" \
  "error: dotsteward: versions.lock.json lacks nix_packages.starship.expected (required by component shell)"
assert_nix_fails "dsLib.pinAt $lock \"nix_packages.example-term.official_tag\" \"example-term\"" \
  "error: dotsteward: versions.lock.json lacks nix_packages.example-term.official_tag (required by component example-term)"
assert_nix_fails "dsLib.pinAt $lock \"flake_inputs.herdr.version\" \"herdr\"" \
  "error: dotsteward: versions.lock.json lacks flake_inputs.herdr.version (required by component herdr)"
assert_nix_fails "dsLib.pinAt $lock \"desktop_packages.vscode\" \"vscode\"" \
  "error: dotsteward: versions.lock.json lacks desktop_packages.vscode (required by component vscode)"
assert_nix_fails "dsLib.pinAt $lock \"schema_version.major\" \"core\"" \
  "error: dotsteward: versions.lock.json lacks schema_version.major (required by component core)"

# Only the path is forced, never sibling values.
assert_nix_eq '1' 'dsLib.pinAt { a = { b = 1; c = throw "sibling forced"; }; d = throw "section forced"; } "a.b" "core"'

# Malformed paths are programming errors.
for path in '' 'a..b' '.a' 'a.'; do
  assert_nix_fails "dsLib.pinAt $lock \"$path\" \"shell\"" \
    "error: dotsteward: invalid lock path \"$path\" (required by component shell)"
done
