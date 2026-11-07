# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness
# The platforms and methods of the github-release-deb components: Linux
# with the deb method only. An instance that also builds for darwin leaves
# them out there (the platform filter); one that asks for another method is
# refused by the supported-method assertion of lib.mkInstance.
# shellcheck source=tests/nix/components/github-release-deb/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/github-release-deb/helpers.sh"

assert_craft_eq '"deb"' '(entryOf (craft { case = "two-systems"; }) "x86_64-linux" "pdfcraft").method' \
  "deb on Linux in a two-system instance"
assert_craft_eq '"platform"' '(entryOf (craft { case = "two-systems"; }) "aarch64-darwin" "pdfcraft").unavailable' \
  "darwin leaves a Linux-only component out (the platform filter)"
assert_craft_fails '(craft { case = "method-external"; }).dotstewardManifest.x86_64-linux.system' \
  "dotsteward: component deckcraft does not support method external on linux (supported: deb)"
