# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# lib.mkInstance outputs (3.2): names, the check identity's Home Manager
# configuration, mkHome defaults, checks per profile and alias, apps.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

assert_inst_eq '["apps","checks","dotstewardManifest","dotstewardMirrors","homeConfigurations","lib","packages"]' \
  'builtins.attrNames example' "output names"
assert_inst_eq '["mkHome","pinnedVersions","pinnedVersionsFor"]' 'builtins.attrNames example.lib' "lib names"

# One entry per system of nix.systems.
for output in packages checks dotstewardManifest apps lib.pinnedVersionsFor; do
  assert_inst_eq '["aarch64-darwin","x86_64-linux"]' "builtins.attrNames example.$output" "example $output systems"
  assert_inst_eq '["x86_64-linux"]' "builtins.attrNames minimal.$output" "minimal $output systems"
done

# homeConfigurations.<identity.username>: the check profile on the primary
# system with the check home.
assert_inst_eq '["alice"]' 'builtins.attrNames example.homeConfigurations' "homeConfigurations names"
assert_inst_eq '{"profile":"workstation","home":"/home/alice","user":"alice","system":"x86_64-linux"}' \
  'let c = example.homeConfigurations.alice; in {
    profile = c.config.dotsteward.profile;
    home = c.config.home.homeDirectory;
    user = c.config.home.username;
    system = c.pkgs.stdenv.hostPlatform.system;
  }' "check configuration"

# mkHome: the default profile when none is given, the primary system when no
# system is given, any configured system on request.
assert_inst_eq '{"profile":"workstation","system":"x86_64-linux","home":"/home/alice"}' \
  'let c = example.lib.mkHome { username = "alice"; homeDirectory = "/home/alice"; }; in {
    profile = c.config.dotsteward.profile;
    system = c.pkgs.stdenv.hostPlatform.system;
    home = c.config.home.homeDirectory;
  }' "mkHome defaults"
assert_inst_eq '{"profile":"fresh","system":"aarch64-darwin"}' \
  'let c = example.lib.mkHome { username = "alice"; homeDirectory = "/Users/alice"; profile = "fresh"; system = "aarch64-darwin"; }; in {
    profile = c.config.dotsteward.profile;
    system = c.pkgs.stdenv.hostPlatform.system;
  }' "mkHome profile and system"
assert_inst_fails 'example.lib.mkHome { username = "alice"; homeDirectory = "/home/alice"; system = "riscv64-linux"; }' \
  "dotsteward: mkHome: system riscv64-linux is not in nix.systems (x86_64-linux, aarch64-darwin)"

# Checks: home-<profile> per profile, home (check profile), check_aliases,
# component packages with check = true and the instance checks.
expected='["dotsteward-manifest","example-app","fresh-home","home","home-fresh","home-workstation","instance-contract","instance-static","manifest-consistent"]'
assert_inst_eq "$expected" 'builtins.attrNames example.checks.x86_64-linux' "example checks"
assert_inst_eq "$expected" 'builtins.attrNames example.checks.aarch64-darwin' "example darwin checks"
assert_inst_eq '["dotsteward-manifest","home","home-workstation","instance-contract","instance-static","manifest-consistent"]' \
  'builtins.attrNames minimal.checks.x86_64-linux' "minimal checks"

# Home checks are the activation packages of the check identity per profile.
assert_inst_eq '{"home":true,"alias":true,"workstation":true,"fresh":true,"darwin":true}' \
  'let
    checks = example.checks.x86_64-linux;
    activation = system: profile: (example.lib.mkHome {
      username = "alice";
      homeDirectory = if system == "aarch64-darwin" then "/Users/alice" else "/home/alice";
      inherit profile system;
    }).activationPackage.drvPath;
  in {
    home = checks.home.drvPath == checks.home-workstation.drvPath;
    alias = checks.fresh-home.drvPath == checks.home-fresh.drvPath;
    workstation = checks.home-workstation.drvPath == activation "x86_64-linux" "workstation";
    fresh = checks.home-fresh.drvPath == activation "x86_64-linux" "fresh";
    darwin = example.checks.aarch64-darwin.home.drvPath == activation "aarch64-darwin" "workstation";
  }' "home checks"
assert_inst_eq 'true' \
  'example.checks.x86_64-linux.example-app.drvPath == example.packages.x86_64-linux.example-app.drvPath' \
  "package check"

# extraChecks are added with the package context; a built-in name is refused.
assert_inst_eq '{"names":["extra-one"],"system":"x86_64-linux"}' \
  'let
    i = instance { extraChecks = ctx: { extra-one = { inherit (ctx) system; }; }; };
  in {
    names = builtins.filter (n: n == "extra-one") (builtins.attrNames i.checks.x86_64-linux);
    system = i.checks.x86_64-linux.extra-one.system;
  }' "extraChecks"
assert_inst_fails '(instance { extraChecks = ctx: { home = ctx.pkgs.hello; }; }).checks.x86_64-linux' \
  "dotsteward: check home is defined twice (by mkInstance and by extraChecks)"

# apps.<system>.default runs the instance CLI.
assert_inst_eq '{"type":"app","program":true}' \
  'let app = example.apps.x86_64-linux.default; in {
    inherit (app) type;
    program = app.program == "${example.packages.x86_64-linux.dotsteward}/bin/dotsteward";
  }' "apps.default"

# root defaults to inputs.self; config to root + "/workstation.toml".
assert_inst_eq '"workstation"' \
  '(dsLib.mkInstance { inputs = inputsFor exampleRoot; }).homeConfigurations.alice.config.dotsteward.profile' \
  "root defaults to inputs.self"
assert_inst_eq '"nix"' \
  '(instance { config = fixtures + "/cases/method-config.toml"; }).homeConfigurations.alice.config.dotsteward.components.example-term.method' \
  "explicit config"
