# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# Component modules (3.2 steps 5 and 6): enabled instance components from
# components/<name>/default.nix, the values mkInstance sets from
# [components.<name>] (enable, profiles, options, resolved method), then
# homeModules and home.nix.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

# Only enabled components are imported (example-off's module throws).
assert_inst_eq '["example-app","example-term"]' \
  'builtins.attrNames (homeOf example "x86_64-linux" "workstation").dotsteward.components' "imported components"

# Values from workstation.toml.
assert_inst_eq '{"app":{"enable":true,"profiles":null,"options":{}},"term":{"enable":true,"profiles":["workstation"],"options":{"greeting":"hello from options"}}}' \
  'let
    c = (homeOf example "x86_64-linux" "workstation").dotsteward.components;
    pick = component: { inherit (component) enable profiles options; };
  in { app = pick c.example-app; term = pick c.example-term; }' "enable, profiles and options"

# Components read their options; home.file content may depend on them.
assert_inst_eq '"hello from options\n"' \
  '(homeOf example "x86_64-linux" "workstation").home.file.".example-term/greeting".text' "options in the module"

# Method resolution: method_by_platform, then method, then the component
# default (set with lib.mkDefault).
methods() {
  inst_json "let m = i: system: (homeOf i system \"workstation\").dotsteward.components.example-term.method; in
    [ (m ($1) \"x86_64-linux\") (m ($1) \"aarch64-darwin\") ]"
}
assert_eq '["official-binary","nix"]' "$(methods example | jq -c .)" "component default and method_by_platform"
assert_eq '["nix","nix"]' "$(methods 'instance { case = "method-config"; }' | jq -c .)" "method"
assert_eq '["official-binary","nix"]' "$(methods 'instance { case = "method-platform"; }' | jq -c .)" \
  "method_by_platform over method"
assert_inst_eq '"nix"' \
  '(homeOf example "x86_64-linux" "workstation").dotsteward.components.example-app.method' "default of example-app"

# The manifest lists the components in [components] order with their source
# and resolved method.
assert_inst_eq '[{"name":"example-term","source":"instance","method":"official-binary"},{"name":"example-app","source":"instance","method":"nix"}]' \
  'map (c: { inherit (c) name source method; }) example.dotstewardManifest.x86_64-linux.components' \
  "manifest components"

# homeModules, then home.nix (when present), are appended after the
# components.
assert_inst_eq '{"extra":"from homeModules\n","home":"from home.nix\n"}' \
  'let c = homeOf (instance { homeModules = [ { home.file.".extra".text = "from homeModules\n"; } ]; }) "x86_64-linux" "workstation"; in {
    extra = c.home.file.".extra".text;
    home = c.home.file.".example-home".text;
  }' "homeModules and home.nix"
assert_inst_eq 'false' \
  '(homeOf minimal "x86_64-linux" "workstation").home.file ? ".example-home"' "no home.nix"

# Special arguments of every module.
assert_inst_eq '{"profile":"fresh","username":"alice","homeDirectory":"/Users/alice","system":"aarch64-darwin","cfg":"workstation","packages":true,"pins":"1.2.3","inputs":true,"root":true}' \
  'let
    probe = { profile, username, homeDirectory, packages, pins, inputs, dotsteward, lib, ... }: {
      options.probe = lib.mkOption { type = lib.types.anything; };
      config.probe = {
        inherit profile username homeDirectory;
        inherit (dotsteward) system;
        cfg = dotsteward.cfg.instance.name;
        packages = packages ? example-term;
        pins = pins.nix_packages.example-app.expected;
        inputs = inputs ? dotsteward;
        root = dotsteward.root == exampleRoot;
      };
    };
  in (homeOf (instance { homeModules = [ probe ]; }) "aarch64-darwin" "fresh").probe' "special arguments"
