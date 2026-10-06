# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Nix parity: for every workstation.toml fixture (the Nix library fixtures and
# tests/cli/config/fixtures/parity) and three catalogs, the Python reader
# (cli/python/dotsteward_cli/config.py) reports exactly the validation
# messages of lib/config.nix, in the same order, and resolves a valid file to
# exactly the same value, with and without an instance-name fallback.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"
# shellcheck source=tests/cli/config/helpers.sh
source "$DS_REPO_ROOT/tests/cli/config/helpers.sh"

files=()
for file in "$nix_valid_fixtures"/*.toml "$nix_invalid_fixtures"/*.toml "$config_fixtures"/parity/*.toml; do
  files+=("$file")
done
((${#files[@]} >= 30)) || ds_fail "expected at least 30 fixtures, found ${#files[@]}"

list=$DS_TEST_ROOT/files.json
for file in "${files[@]}"; do
  jq -n --arg name "${file#"$DS_REPO_ROOT"/tests/}" --arg path "$file" '{ name: $name, path: $path }'
done | jq -s . >"$list"

declare -A catalogs
catalogs[canonical]=$(config_catalog)
catalogs[partial]="zz-extra,herdr,example-term"
catalogs[empty]=""

# One Nix evaluation for every file and catalog.
nix_all=$(nix_lib_json "let
  files = builtins.fromJSON (builtins.readFile (/. + \"$list\"));
  catalogs = {
    canonical = testCatalog;
    partial = [ \"zz-extra\" \"herdr\" \"example-term\" ];
    empty = [ ];
  };
  one = catalog: f:
    let
      raw = builtins.fromTOML (builtins.readFile (/. + f.path));
      problems = dsLib.config.errors { inherit catalog; } raw;
    in
    { inherit (f) name; errors = problems; }
    // lib.optionalAttrs (problems == [ ]) {
      resolved = dsLib.config.resolve { inherit catalog; } raw;
      named = dsLib.config.resolve { inherit catalog; instanceName = \"from-dir\"; } raw;
    };
in lib.mapAttrs (_: catalog: map (one catalog) files) catalogs")

resolved_count=0
for catalog_name in canonical partial empty; do
  catalog=${catalogs[$catalog_name]}
  for ((i = 0; i < ${#files[@]}; i++)); do
    file=${files[i]}
    name=$(jq -r --argjson i "$i" '.[$i].name' "$list")
    expected=$(jq -c --arg c "$catalog_name" --argjson i "$i" '.[$c][$i]' <<<"$nix_all")
    label="$name (catalog $catalog_name)"

    actual_errors=$(config_py --file "$file" --catalog "$catalog" errors) ||
      ds_fail "errors failed for $label"
    assert_eq "$(jq -c .errors <<<"$expected")" "$(jq -c . <<<"$actual_errors")" "messages of $label"

    if jq -e 'has("resolved")' >/dev/null <<<"$expected"; then
      resolved_count=$((resolved_count + 1))
      actual=$(config_py --file "$file" --catalog "$catalog" resolve) || ds_fail "resolve failed for $label"
      assert_eq "$(jq -S .resolved <<<"$expected")" "$(jq -S . <<<"$actual")" "resolved $label"
      actual=$(config_py --file "$file" --catalog "$catalog" --instance-name from-dir resolve) ||
        ds_fail "resolve with an instance name failed for $label"
      assert_eq "$(jq -S .named <<<"$expected")" "$(jq -S . <<<"$actual")" "resolved $label with an instance name"
    else
      assert_exit 1 config_py --file "$file" --catalog "$catalog" resolve
      assert_contains "$DS_STDERR" "[dotsteward] ERROR: workstation.toml: $(jq -r '.errors[0]' <<<"$expected")" \
        "resolve reports the first message of $label"
    fi
  done
done
((resolved_count >= 15)) || ds_fail "expected at least 15 resolved cases, got $resolved_count"

# The golden resolved configurations of the Nix library tests hold for the
# Python reader too, independently of the live evaluation above.
for name in minimal full; do
  actual=$(config_py --file "$nix_valid_fixtures/$name.toml" --catalog "$(config_catalog)" resolve)
  assert_eq "$(jq -S . "$nix_valid_fixtures/$name.expected.json")" "$(jq -S . <<<"$actual")" "golden $name"
done
