# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# A deb pin is the floor of its package: the install verifies it, and `dotsteward upgrade` moves
# it, against the installed version of install.deb.packageNames. A deb component with a pin and
# no package names could never install and its floor would never move, so the evaluation refuses
# it and names the component and its pin. Without a pin (apt only) no package names are needed.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# deb_home INSTALL: the home of the workstation profile with example-app as a deb component of
# the install block INSTALL.
deb_home() {
  printf '(homeOf { config = "workstation"; modules = componentModules ++ [ { dotsteward.components.example-app = { method = lib.mkForce "deb"; supportedMethods.linux = lib.mkForce [ "deb" ]; install.deb = %s; }; } ]; }).home.username' "$1"
}

assert_core_fails "$(deb_home '{ pin = "desktop_packages.example-app"; }')" \
  "- dotsteward: component example-app (deb): install.deb.pin desktop_packages.example-app needs install.deb.packageNames"
assert_core_eq '"alice"' "$(deb_home '{ pin = "desktop_packages.example-app"; packageNames = [ "example-app" ]; }')" \
  "a pin with its package names"
assert_core_eq '"alice"' "$(deb_home '{ apt = [ "example-tool" ]; }')" "apt only"
