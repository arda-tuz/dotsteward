# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# Catalog components: modules/components/<name> of the framework (lib.catalog)
# with their package.nix, and an instance component that replaces a catalog
# name with source = "instance". The framework checkout is copied without
# its real catalog (modules/components) and given one synthetic catalog
# component, so the test does not depend on the real catalog.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

framework=$DS_TEST_ROOT/framework
mkdir -p "$framework/tests/nix" "$framework/tests/fixtures"
for entry in VERSION lib modules nix cli schema privacy; do
  [[ -e $DS_REPO_ROOT/$entry ]] && cp -R "$DS_REPO_ROOT/$entry" "$framework/"
done
cp -R "$DS_REPO_ROOT/tests/nix/instance" "$framework/tests/nix/"
cp -R "$DS_REPO_ROOT/tests/fixtures/instances" "$framework/tests/fixtures/"
chmod -R u+w "$framework"
rm -rf "$framework/modules/components"

catalog=$framework/modules/components/example-cat
mkdir -p "$catalog"
cat >"$catalog/default.nix" <<'EOF'
{ lib, packages, ... }:
{
  dotsteward.components.example-cat = {
    method = lib.mkDefault "nix";
    supportedMethods = {
      linux = [ "nix" ];
      darwin = [ "nix" ];
    };
    install.nix.packages = [ packages.example-cat ];
    pins.resolvedVersions.example-cat = "3.0.0";
    checks.commands = [ "example-cat" ];
  };
}
EOF
cat >"$catalog/package.nix" <<'EOF'
{ pkgs, packages, ... }:
{
  example-cat = {
    package = pkgs.writeShellScriptBin "example-cat" "exec ${packages.example-app}/bin/example-app";
    check = true;
  };
}
EOF

root=$(instance_copy "$nix_instance_fixtures/example")
cat >>"$root/workstation.toml" <<'EOF'

[components.example-cat]
enable = true
EOF
# [components] order lists only the instance components; the catalog name is
# appended after them.
eval_catalog() {
  nix_instance_eval_in "$framework" "let i = instance { root = /. + \"$root\"; }; in $1" ||
    ds_fail "evaluation failed: $1: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

assert_eq '["example-cat"]' "$(eval_catalog 'builtins.attrNames dsLib.catalog' | jq -c .)" "catalog"
assert_eq '[{"name":"example-term","source":"instance"},{"name":"example-app","source":"instance"},{"name":"example-cat","source":"catalog"}]' \
  "$(eval_catalog 'map (c: { inherit (c) name source; }) i.dotstewardManifest.x86_64-linux.components' | jq -c .)" \
  "catalog component in the manifest"
assert_eq '{"check":true,"fixpoint":true,"home":true,"pinned":"3.0.0"}' \
  "$(eval_catalog '{
    check = i.checks.x86_64-linux.example-cat.drvPath == i.packages.x86_64-linux.example-cat.drvPath;
    fixpoint = lib.hasInfix (storeless "${i.packages.x86_64-linux.example-app}") (storeless i.packages.x86_64-linux.example-cat.text);
    home = builtins.elem "example-cat" (map lib.getName (homeOf i "x86_64-linux" "workstation").home.packages);
    pinned = i.lib.pinnedVersions.example-cat;
  }' | jq -cS .)" "catalog package and pins"

# A disabled catalog component is neither imported nor packaged.
sed -i '/^\[components.example-cat\]$/,$d' "$root/workstation.toml"
assert_eq '{"components":false,"packages":false}' \
  "$(eval_catalog '{
    components = (homeOf i "x86_64-linux" "workstation").dotsteward.components ? example-cat;
    packages = i.packages.x86_64-linux ? example-cat;
  }' | jq -cS .)" "disabled catalog component"

# source = "instance" replaces the catalog module and package.nix with the
# instance's components/<name>.
mkdir -p "$root/components/example-cat"
cat >"$root/components/example-cat/default.nix" <<'EOF'
{ lib, ... }:
{
  dotsteward.components.example-cat = {
    method = lib.mkDefault "external";
    supportedMethods = {
      linux = [ "external" ];
      darwin = [ "external" ];
    };
    pins.resolvedVersions.example-cat = "4.0.0-instance";
  };
}
EOF
cat >>"$root/workstation.toml" <<'EOF'

[components.example-cat]
enable = true
source = "instance"
EOF
assert_eq '{"method":"external","packages":false,"pinned":"4.0.0-instance","source":"instance"}' \
  "$(eval_catalog '{
    method = (homeOf i "x86_64-linux" "workstation").dotsteward.components.example-cat.method;
    packages = i.packages.x86_64-linux ? example-cat;
    pinned = i.lib.pinnedVersions.example-cat;
    source = (lib.findFirst (c: c.name == "example-cat") null i.dotstewardManifest.x86_64-linux.components).source;
  }' | jq -cS .)" "instance replacement of a catalog name"
