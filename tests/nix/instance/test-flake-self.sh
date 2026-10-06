# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# lib.mkInstance called the way an instance flake calls it (3.2): only
# `inputs`, so the root defaults to inputs.self, and inputs.self is the flake
# result built from the outputs mkInstance returns (the fixpoint of Nix's
# call-flake.nix: outputs = flake.outputs (inputs // { self = result; }),
# result = outputs // sourceInfo // ...). The output names must not depend on
# the root, or the evaluation of every output is an infinite recursion; the
# guards still refuse each output.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

# flakeInstance ROOT ARGS: mkInstance of ARGS with inputs.self the flake
# result of the instance at ROOT, as call-flake.nix builds it.
flake_instance() {
  printf '%s' "let
    flakeInstance = root: args:
      let
        sourceInfo = { outPath = toString root; lastModified = 0; };
        outputs = dsLib.mkInstance (args // { inputs = inputsFor result // args.inputs or { }; });
        result = outputs // sourceInfo // { inherit outputs sourceInfo; _type = \"flake\"; };
      in
      result;
  in ($1)"
}

# The output names, the check identity and the mirrors, equal to those of
# the same instance with an explicit root.
assert_inst_eq '["apps","checks","dotstewardManifest","dotstewardMirrors","homeConfigurations","lib","packages"]' \
  "$(flake_instance 'builtins.attrNames (flakeInstance exampleRoot { }).outputs')" "output names through inputs.self"
assert_inst_eq '["alice"]' \
  "$(flake_instance 'builtins.attrNames (flakeInstance exampleRoot { }).homeConfigurations')" \
  "homeConfigurations through inputs.self"
assert_inst_eq "$(inst_json 'storeless example.dotstewardMirrors')" \
  "$(flake_instance 'storeless (flakeInstance exampleRoot { }).dotstewardMirrors')" "mirrors through inputs.self"
assert_inst_eq "$(inst_json 'example.lib.pinnedVersions')" \
  "$(flake_instance '(flakeInstance exampleRoot { }).lib.pinnedVersions')" "pinned versions through inputs.self"
assert_inst_eq '["dotsteward-manifest","example-app","fresh-home","home","home-fresh","home-workstation","instance-contract","instance-static","manifest-consistent"]' \
  "$(flake_instance 'builtins.attrNames (flakeInstance exampleRoot { }).checks.x86_64-linux')" \
  "checks through inputs.self"
assert_inst_eq '"x86_64-linux"' \
  "$(flake_instance '(flakeInstance exampleRoot { }).homeConfigurations.alice.pkgs.stdenv.hostPlatform.system')" \
  "check configuration through inputs.self"

# The minimal instance (no components) evaluates the same way.
assert_inst_eq "$(inst_json 'storeless minimal.dotstewardMirrors')" \
  "$(flake_instance 'storeless (flakeInstance minimalRoot { }).dotstewardMirrors')" "minimal mirrors through inputs.self"

# The guards still refuse every output, with the output names intact.
for output in homeConfigurations.alice.activationPackage.drvPath lib.pinnedVersions packages.x86_64-linux \
  dotstewardMirrors; do
  assert_inst_fails \
    "$(flake_instance "(flakeInstance exampleRoot { config = fixtures + \"/cases/unknown-component.toml\"; }).$output")" \
    "dotsteward: unknown component example-missing in workstation.toml"
done
assert_inst_fails \
  "$(flake_instance '(flakeInstance exampleRoot { inputs.nixpkgs = nixpkgsInput // { outPath = "/nonexistent/nixpkgs"; }; }).lib.pinnedVersions')" \
  "dotsteward: the framework input has its own nixpkgs"
