# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# lib/default.nix: the exported names, all lazy.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

assert_nix_eq '["catalog","config","contract","mkCli","mkInstance","mkNpmBundle","pinAt","platform","source","version"]' 'lib.attrNames dsLib'
# The framework source as a string; a path is not copied to the store.
assert_nix_eq "$(jq -n --arg s "$DS_REPO_ROOT" '$s')" 'dsLib.source'
assert_nix_eq "\"$(<"$DS_REPO_ROOT/VERSION")\"" 'dsLib.version'
assert_nix_eq '{"config":"set","contract":"set","pinAt":"lambda","platform":"set"}' \
  '{ config = builtins.typeOf dsLib.config; contract = builtins.typeOf dsLib.contract; pinAt = builtins.typeOf dsLib.pinAt; platform = builtins.typeOf dsLib.platform; }'
assert_nix_eq '["errors","load","loadWith","resolve"]' \
  'lib.filter (n: lib.elem n [ "errors" "load" "loadWith" "resolve" ]) (lib.attrNames dsLib.config)'

# The catalog is discovered from modules/components.
expected='[]'
if [[ -d $DS_REPO_ROOT/modules/components ]]; then
  expected=$(find "$DS_REPO_ROOT/modules/components" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort | jq -R . | jq -cs .)
fi
assert_nix_eq "$expected" 'lib.attrNames dsLib.catalog'
