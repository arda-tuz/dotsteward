# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh and config_load
# The default catalog of the Python reader is the framework's own, like
# lib.catalog: the directories of modules/components in a checkout, or the
# catalog.json the package writes next to cli/ (the package has no
# modules/), or no catalog at all.
# shellcheck source=tests/cli/config/helpers.sh
source "$DS_REPO_ROOT/tests/cli/config/helpers.sh"

instance=$DS_TEST_ROOT/ws
make_instance "$instance"
printf '[components.example-term]\nenable = true\n' >>"$instance/workstation.toml"

order_with() {
  load_config "$1" "$instance"
  printf '%s\n' "${DS_COMPONENTS_ORDER[*]}"
}

# A checkout: catalog directories in canonical order, unknown catalog names
# sorted after them; files and instance components are not catalog names.
checkout=$DS_TEST_ROOT/checkout
make_framework "$checkout" vscode shell zz-new herdr
touch "$checkout/modules/components/README.md"
assert_eq "shell herdr vscode zz-new example-term" "$(order_with "$checkout")"
load_config "$checkout" "$instance"
assert_eq catalog "${DS_COMPONENT_SOURCE[zz-new]}"
assert_eq instance "${DS_COMPONENT_SOURCE[example-term]}"

# The package layout: catalog.json, no modules/.
package=$DS_TEST_ROOT/package
make_framework "$package"
rm -rf "$package/modules"
printf '["codex","shell"]\n' >"$package/catalog.json"
assert_eq "shell codex example-term" "$(order_with "$package")"

# Neither: no catalog components.
bare=$DS_TEST_ROOT/bare
make_framework "$bare"
rm -rf "$bare/modules"
assert_eq "example-term" "$(order_with "$bare")"

# A malformed catalog.json is an error, not an empty catalog.
printf '{"shell": true}\n' >"$package/catalog.json"
assert_exit 1 order_with "$package"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid catalog file $package/catalog.json"

# --catalog overrides the default; an empty value means no catalog.
assert_eq '["example-term"]' \
  "$(cd "$instance" && config_py --catalog '' resolve | jq -c .components.order)"
assert_eq '["herdr","example-term"]' \
  "$(cd "$instance" && config_py --catalog herdr resolve | jq -c .components.order)"

# The framework under test: its catalog equals lib.catalog (the
# modules/components directories), whatever exists at this point.
expected='[]'
if [[ -d $DS_REPO_ROOT/modules/components ]]; then
  expected=$(find "$DS_REPO_ROOT/modules/components" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    LC_ALL=C sort | jq -R . | jq -cs .)
fi
actual=$(cd "$instance" && config_py resolve |
  jq -c '[.components | to_entries[] | select(.value | type == "object" and .source == "catalog") | .key] | sort')
assert_eq "$expected" "$actual"
