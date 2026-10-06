# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# checks.<system>.instance-static (the [gate] static scripts, run from a
# copy of the instance root) and checks.<system>.instance-contract (the
# framework's checks over the instance: static rules, the offline pins
# check, the settings buffer against the evaluated component targets and
# the generic privacy scan). Both run with ShellCheck from the instance
# nixpkgs. The sandbox builds, including a contract that passes end to end
# and one that fails on a ShellCheck finding, run in checks.nix-instance.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

assert_inst_eq '{"name":"instance-static","script":true,"instance":true}' \
  'let c = example.checks.x86_64-linux.instance-static; in {
    inherit (c) name;
    script = lib.hasInfix "dotsteward static --sandbox --only scripts" c.buildCommand;
    instance = lib.hasInfix "DOTSTEWARD_INSTANCE=" c.buildCommand;
  }' "instance-static"
assert_inst_eq 'false' \
  'lib.hasInfix "static.sh" minimal.checks.x86_64-linux.instance-static.buildCommand' "no static scripts"

copy=$(instance_copy "$nix_instance_fixtures/example")
sed -i 's|static = \["tests/static.sh"\]|static = ["tests/static.sh", "tests/missing.sh"]|' "$copy/workstation.toml"
assert_inst_fails "(instance { root = /. + \"$copy\"; }).checks.x86_64-linux.instance-static.drvPath" \
  "dotsteward: [gate] static: tests/missing.sh does not exist in the instance"

# instance-contract runs every step, in order; settings validate sees the
# component targets through --targets-file (the evaluated manifest's
# settings targets and reload hooks), not only the buffer's own targets.
# Its privacy scan is the instance scan inside static (SPEC 11.2, D4): no
# separate `scan`, which would apply the framework policy (home paths,
# e-mail addresses, non-ASCII text) to personal instance content.
assert_inst_eq '{"static":true,"pins":true,"settings":true,"scan":true,"order":true,"targets":true,"shellcheck":true}' \
  'let
    c = example.checks.x86_64-linux.instance-contract;
    command = storeless c.buildCommand;
    at = needle: lib.stringLength (lib.head (builtins.split needle command));
    settings = storeless "dotsteward settings --targets-file ${c.targetsFile} validate";
  in {
    static = lib.hasInfix "dotsteward static --sandbox\n" command;
    pins = lib.hasInfix "dotsteward pins check\n" command;
    settings = lib.hasInfix settings command;
    scan = !(lib.hasInfix "dotsteward scan" command);
    order = at "dotsteward static " < at "dotsteward pins "
      && at "dotsteward pins " < at "dotsteward settings ";
    targets = lib.hasPrefix "dotsteward-settings-targets" c.targetsFile.name;
    shellcheck = lib.any (p: lib.toLower (lib.getName p) == "shellcheck") c.nativeBuildInputs;
  }' "instance-contract steps"
assert_inst_eq 'true' \
  'lib.any (p: lib.toLower (lib.getName p) == "shellcheck") example.checks.x86_64-linux.instance-static.nativeBuildInputs' \
  "instance-static has ShellCheck"
assert_inst_eq 'false' 'example.checks.x86_64-linux.instance-contract ? steps' "no step filter"

# The example fixture is a complete instance for the contract, except for
# the generated files (the mirrors and bootstrap.sh, which checks.nix-instance
# adds): its launcher is the framework's template copy.
assert_eq "$(sha256sum <"$DS_REPO_ROOT/template/.dotsteward/cli.sh")" \
  "$(sha256sum <"$nix_instance_fixtures/example/.dotsteward/cli.sh")" \
  "fixtures/example/.dotsteward/cli.sh equals template/.dotsteward/cli.sh"
