# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The package fixpoint (3.2 step 4): component package.nix files of enabled
# components, extraPackages, the instance CLI and the local-maintained-files
# alias; per system.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

# Enabled components only: example-off's package.nix throws when read.
for system in x86_64-linux aarch64-darwin; do
  assert_inst_eq '["dotsteward","example-app","example-term","local-maintained-files"]' \
    "builtins.attrNames example.packages.$system" "example packages on $system"
done
assert_inst_eq '["dotsteward","local-maintained-files"]' 'builtins.attrNames minimal.packages.x86_64-linux' \
  "minimal packages"

# Each package.nix gets the context; packages is the fixpoint, so
# example-term runs example-app's binary.
assert_inst_eq '{"app":"example-app","term":true,"version":true}' \
  'let p = example.packages.x86_64-linux; in {
    app = lib.getName p.example-app;
    term = lib.hasInfix (storeless "${p.example-app}/bin/example-app") (storeless p.example-term.text);
    version = lib.hasInfix "example-app 1.2.3" p.example-app.text;
  }' "fixpoint"

# The CLI is built with the instance nixpkgs (F8); the alias is the check
# configuration's local-maintained-files.
assert_inst_eq '{"cli":true,"alias":true,"name":"local-maintained-files"}' \
  'let
    p = example.packages.x86_64-linux;
    pkgs = import nixpkgsInput { system = "x86_64-linux"; config.allowUnfree = false; };
  in {
    cli = p.dotsteward.drvPath == (dsLib.mkCli pkgs).drvPath;
    alias = p.local-maintained-files.drvPath == example.homeConfigurations.alice.config.dotsteward.cli.aliasPackage.drvPath;
    name = p.local-maintained-files.name;
  }' "cli and alias"

# Without the alias there is no local-maintained-files package.
assert_inst_eq '["dotsteward","example-app","example-term"]' \
  'builtins.attrNames (instance { homeModules = [ { dotsteward.cli.alias = false; } ]; }).packages.x86_64-linux' \
  "alias disabled"

# Home Manager sees the same package set: example-app (method nix) is in
# home.packages; on darwin example-term (nix there) too.
assert_inst_eq '{"linux":true,"darwin":true}' \
  'let
    names = c: map lib.getName c.home.packages;
  in {
    linux = builtins.elem "example-app" (names (homeOf example "x86_64-linux" "workstation"));
    darwin = builtins.elem "example-term" (names (homeOf example "aarch64-darwin" "workstation"));
  }' "packages in Home Manager"

# extraPackages come last: they see the context and may replace a component
# package, which every consumer of the fixpoint then sees.
assert_inst_eq '{"keys":["cfg","dsLib","inputs","lib","packages","pins","pkgs","root","system"],"term":"example-term-extra","home":true,"system":"aarch64-darwin"}' \
  'let
    i = instance {
      extraPackages = ctx: {
        probe = { keys = builtins.attrNames ctx; inherit (ctx) system; };
        example-term = ctx.pkgs.writeShellScriptBin "example-term-extra" "exit 0";
      };
    };
    darwin = i.packages.aarch64-darwin;
  in {
    inherit (darwin.probe) keys system;
    term = lib.getName darwin.example-term;
    home = builtins.elem "example-term-extra" (map lib.getName (homeOf i "aarch64-darwin" "workstation").home.packages);
  }' "extraPackages"

# package.nix values: a derivation or { package; check ? false; }.
copy=$(instance_copy "$nix_instance_fixtures/example")
cat >"$copy/components/example-term/package.nix" <<'EOF'
{ pkgs, ... }:
{
  example-term = pkgs.hello;
  example-app = pkgs.hello;
}
EOF
assert_inst_fails "(instance { root = /. + \"$copy\"; }).packages.x86_64-linux" \
  "dotsteward: package example-app is declared by components example-app and example-term"

cat >"$copy/components/example-term/package.nix" <<'EOF'
{ ... }:
{
  example-term = 42;
}
EOF
assert_inst_fails "(instance { root = /. + \"$copy\"; }).packages.x86_64-linux.example-term" \
  "dotsteward: components/example-term/package.nix: example-term must be a derivation or { package; check ? false; }"

cat >"$copy/components/example-term/package.nix" <<'EOF'
{ pkgs, ... }:
{
  example-term = {
    package = pkgs.hello;
    check = "yes";
  };
}
EOF
assert_inst_fails "(instance { root = /. + \"$copy\"; }).checks.x86_64-linux" \
  "dotsteward: components/example-term/package.nix: example-term.check must be a boolean"

cat >"$copy/components/example-term/package.nix" <<'EOF'
{
  example-term = null;
}
EOF
assert_inst_fails "(instance { root = /. + \"$copy\"; }).packages.x86_64-linux" \
  "dotsteward: components/example-term/package.nix must be a function of the package context"

# Reserved names are refused.
cat >"$copy/components/example-term/package.nix" <<'EOF'
{ pkgs, ... }:
{
  dotsteward = pkgs.hello;
}
EOF
assert_inst_fails "(instance { root = /. + \"$copy\"; }).packages.x86_64-linux" \
  "dotsteward: components/example-term/package.nix: dotsteward is reserved"
