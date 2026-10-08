# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# checks.<system>.manifest-consistent: the manifest of every profile
# equals the manifest of the check profile; a contract option that depends
# on the profile fails the evaluation with the differing keys.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

assert_inst_eq '{"linux":"manifest-consistent","darwin":"manifest-consistent","minimal":"manifest-consistent"}' \
  '{
    linux = example.checks.x86_64-linux.manifest-consistent.name;
    darwin = example.checks.aarch64-darwin.manifest-consistent.name;
    minimal = minimal.checks.x86_64-linux.manifest-consistent.name;
  }' "consistent instances"

# Home files may depend on the profile; the check still passes.
assert_inst_eq '"manifest-consistent"' \
  '(instance { homeModules = [ ({ profile, ... }: { home.file.".profile-name".text = profile; }) ]; }).checks.x86_64-linux.manifest-consistent.name' \
  "profile-dependent home files"

# A contract option that depends on the profile.
violation='instance { homeModules = [ ({ lib, profile, ... }: {
  dotsteward.components.example-app.checks.commands = lib.mkIf (profile == "fresh") [ "fresh-only" ];
}) ]; }'
assert_inst_fails "($violation).checks.x86_64-linux.manifest-consistent.drvPath" \
  "dotsteward: the manifest of profile fresh differs from the manifest of profile workstation on x86_64-linux (keys: checks)" \
  "must not depend on the profile"
assert_inst_fails "($violation).checks.aarch64-darwin.manifest-consistent.drvPath" \
  "on aarch64-darwin (keys: checks)"
