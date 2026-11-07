# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The platform filter: a component of the common intent that one configured system cannot
# have (its platform, or the method on that platform) is left out of that system instead of
# failing the evaluation, and the manifest of that system says why (unavailable). A method
# asked for one platform explicitly stays an error, and so does a component no configured
# system can have.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

filter='instance { case = "platform-filter"; }'
entry() {
  printf '(lib.findFirst (c: c.name == "%s") null (%s).dotstewardManifest.%s.components)' "$1" "$filter" "$2"
}

# Linux keeps both, without a word.
assert_inst_eq 'null' "($(entry example-linux x86_64-linux)).unavailable or null" "example-linux on Linux"
assert_inst_eq 'null' "($(entry example-app x86_64-linux)).unavailable or null" "example-app on Linux"

# darwin evaluates and leaves them out, each with its reason.
assert_inst_eq '"platform"' "($(entry example-linux aarch64-darwin)).unavailable" "example-linux on darwin"
assert_inst_eq '"method"' "($(entry example-app aarch64-darwin)).unavailable" "example-app on darwin"
darwin_home="(($filter).lib.mkHome { username = \"alice\"; homeDirectory = \"/Users/alice\"; profile = \"workstation\"; system = \"aarch64-darwin\"; })"
assert_inst_eq 'false' "lib.any (p: lib.hasInfix \"example-app\" (p.name or \"\")) $darwin_home.config.home.packages" \
  "the package of a component that is left out is not installed"

# Asked for darwin explicitly: the error names the platform.
assert_inst_fails '(instance { case = "platform-explicit"; }).dotstewardManifest.aarch64-darwin.system' \
  "Failed assertions:" \
  "dotsteward: component example-linux does not support darwin (nix.systems contains aarch64-darwin; supported: linux)"

# No configured system can have it: the error stays.
assert_inst_fails '(instance { case = "unsupported-method"; }).homeConfigurations.alice.activationPackage.drvPath' \
  "Failed assertions:" \
  "dotsteward: component example-app does not support method deb on linux (supported: nix, external)"
