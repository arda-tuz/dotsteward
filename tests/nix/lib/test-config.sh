# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# lib/config.nix: workstation.toml loading, static and derived defaults.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

# Golden resolved configurations (every key present, defaults filled).
for name in minimal full; do
  assert_nix_eq "$(<"$nix_lib_fixtures/valid/$name.expected.json")" \
    "loadFixture \"valid/$name\"" "resolved valid/$name"
done

# A darwin-only instance accepts a macOS short name and fills the rest.
# shellcheck disable=SC2016 # a Nix expression, not a shell expansion
actual=$(nix_lib_json 'let c = loadFixture "valid/darwin-only"; in {
  inherit (c.identity) username home darwin_home;
  inherit (c.instance) name checkout;
  inherit (c.profiles) default check bootstrap;
  modes = map (p: c.profiles.${p}.mode) c.profiles.names;
  order = c.components.order;
  vscode = c.components.vscode.method_by_platform;
  term = c.components.example-term.source;
}')
assert_eq '{"bootstrap":"fresh","check":"laptop","checkout":"~/mac-workstation","darwin_home":"/Users/Alice","default":"fresh","home":"/home/Alice","modes":["adopt","fresh"],"name":"mac-workstation","order":["shell","herdr","claude-code","codex","opencode-pi","vscode","example-term"],"term":"instance","username":"Alice","vscode":{"darwin":"app-archive","linux":null}}' \
  "$(jq -cS . <<<"$actual")" "darwin-only derived values"

# instance.name falls back to the caller's directory name, and checkout
# follows it; values in the file win over the fallback.
minimal=$nix_lib_fixtures/valid/minimal.toml
assert_nix_eq '{"name":"workstation","checkout":"~/workstation"}' \
  "let i = (dsLib.config.loadWith { catalog = testCatalog; instanceName = \"workstation\"; } (/. + \"$minimal\")).instance; in { inherit (i) name checkout; }" \
  "instance name fallback"
full=$nix_lib_fixtures/valid/full.toml
assert_nix_eq '"workstation"' \
  "(dsLib.config.loadWith { catalog = testCatalog; instanceName = \"other\"; } (/. + \"$full\")).instance.name" \
  "file value wins over the fallback"

# The order lists the given components first, then the remaining catalog
# components in catalog order, then the instance components sorted.
file=$(toml_fixture order "$(<"$minimal")
[components]
order = [\"codex\", \"example-term\"]
[components.example-term]
enable = true
[components.example-app]
enable = true")
assert_nix_eq '["codex","example-term","shell","herdr","claude-code","opencode-pi","vscode","example-app"]' \
  "(loadToml \"$file\").components.order" "order completion"

# A catalog name may be provided by the instance instead.
file=$(toml_fixture shadow "$(<"$minimal")
[components.shell]
enable = true
source = \"instance\"")
assert_nix_eq '"instance"' "(loadToml \"$file\").components.shell.source" "instance shadows a catalog name"

# The catalog parameter decides the default source and order; the default
# catalog is the framework's own catalog directories.
assert_nix_eq '{"order":["shell","herdr"],"source":"catalog"}' \
  "let c = dsLib.config.loadWith { catalog = [ \"herdr\" \"shell\" ]; } (/. + \"$minimal\"); in { inherit (c.components) order; source = c.components.herdr.source; }" \
  "explicit catalog, in canonical catalog order"
catalog_json=$(nix_lib_json 'lib.attrNames dsLib.catalog')
expected_order=$(jq -c --argjson cat "$catalog_json" -n \
  '["shell","herdr","claude-code","codex","opencode-pi","vscode"] | map(select(. as $n | $cat | index($n)))')
assert_nix_eq "$expected_order" "(dsLib.config.load (/. + \"$minimal\")).components.order" "load uses lib.catalog"
assert_nix_eq '["shell","herdr","claude-code","codex","opencode-pi","vscode"]' 'dsLib.config.catalogOrder'

# resolve works on already parsed attributes; errors returns the messages
# without throwing.
assert_nix_eq '"main"' \
  "(dsLib.config.resolve { catalog = testCatalog; } (builtins.fromTOML (builtins.readFile (/. + \"$minimal\")))).profiles.check"
assert_nix_eq '[]' "errorsOfToml \"$minimal\""

# methodFor: method_by_platform, then method, then null (component default).
assert_nix_eq '{"claude":"deb","codex":"external","shell":null,"vscodeLinux":"deb","vscodeDarwin":"app-archive"}' \
  'let c = loadFixture "valid/full"; m = dsLib.config.methodFor c; in {
     claude = m "claude-code" "linux"; codex = m "codex" "darwin"; shell = m "shell" "linux";
     vscodeLinux = m "vscode" "linux"; vscodeDarwin = m "vscode" "darwin"; }'

# The parsed schema is exported.
assert_nix_eq "$(jq -c .title "$DS_REPO_ROOT/schema/workstation.schema.json")" 'dsLib.config.schema.title'
