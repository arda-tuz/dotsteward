# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# Evaluation guards (3.8): every case fails with a message that names the
# problem. checks.nix-assertions evaluates the same cases with
# builtins.tryEval in the flake; this file checks the messages.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

home=homeConfigurations.alice.activationPackage.drvPath

# Unknown profile (core assertion).
assert_inst_fails '(example.lib.mkHome { username = "alice"; homeDirectory = "/home/alice"; profile = "nope"; }).activationPackage.drvPath' \
  "Failed assertions:" "Unsupported dotsteward profile: nope"

# home.username differs from the requested username (core assertion).
assert_inst_fails "(instance { homeModules = [ { home.username = lib.mkForce \"mallory\"; } ]; }).$home" \
  "Failed assertions:" "dotsteward: home.username mallory differs from the requested username alice"

# Unknown component name: a [components.<name>] table that is neither a
# catalog component nor components/<name>/default.nix of the instance. Every
# output refuses.
for output in "$home" lib.pinnedVersions packages.x86_64-linux dotstewardMirrors; do
  assert_inst_fails "(instance { case = \"unknown-component\"; }).$output" \
    "dotsteward: unknown component example-missing in workstation.toml" \
    "components/example-missing/default.nix"
done

# An enabled component that does not support a configured system: the Linux
# evaluation passes, the darwin one fails, and so does the mirror check of
# the Linux system (it renders every system).
assert_inst_eq '"x86_64-linux"' '(instance { case = "unsupported-system"; }).dotstewardManifest.x86_64-linux.system' \
  "the Linux evaluation of a Linux-only component"
assert_inst_fails '(instance { case = "unsupported-system"; }).dotstewardManifest.aarch64-darwin.system' \
  "Failed assertions:" \
  "dotsteward: component example-linux does not support darwin (nix.systems contains aarch64-darwin; supported: linux)"
assert_inst_fails '(instance { case = "unsupported-system"; }).checks.x86_64-linux.dotsteward-manifest.drvPath' \
  "dotsteward: component example-linux does not support darwin"

# A method the component does not support on the platform.
assert_inst_fails "(instance { case = \"unsupported-method\"; }).$home" \
  "Failed assertions:" \
  "dotsteward: component example-app does not support method deb on linux (supported: nix, external)"

# A lock key a component needs is missing (pinAt).
assert_inst_fails "(instance { case = \"missing-pin\"; }).$home" \
  "dotsteward: versions.lock.json lacks nix_packages.example-app.expected (required by component example-app)"
assert_inst_fails '(instance { case = "missing-pin"; }).lib.pinnedVersions' \
  "dotsteward: versions.lock.json lacks nix_packages.example-app.expected (required by component example-app)"

# A missing follows: the framework would bring a second nixpkgs or
# home-manager. Every output refuses.
for output in "$home" lib.pinnedVersions packages.x86_64-linux; do
  assert_inst_fails "(instance { inputs.nixpkgs = nixpkgsInput // { outPath = \"/nonexistent/nixpkgs\"; }; }).$output" \
    "dotsteward: the framework input has its own nixpkgs" \
    "inputs.dotsteward.inputs.nixpkgs.follows = \"nixpkgs\""
done
assert_inst_fails "(instance { inputs.home-manager = homeManagerInput // { outPath = \"/nonexistent/home-manager\"; }; }).$home" \
  "dotsteward: the framework input has its own home-manager" \
  "inputs.dotsteward.inputs.home-manager.follows = \"home-manager\""

# A key schema version 1 does not have.
assert_inst_fails "(instance { case = \"unknown-key\"; }).$home" \
  "dotsteward: workstation.toml: unknown key nix.unknown_option"

# Required inputs.
assert_inst_fails 'dsLib.mkInstance { inputs = removeAttrs (inputsFor exampleRoot) [ "home-manager" ]; }' \
  "dotsteward: mkInstance: inputs lacks home-manager (required: self, nixpkgs, home-manager)"
