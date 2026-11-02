# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness
# The platforms and methods of the github-release-deb components: Linux
# with the deb method only. An instance that also builds for darwin, or
# that asks for another method, is refused by the supported-platform and
# supported-method assertions of lib.mkInstance.
# shellcheck source=tests/nix/components/github-release-deb/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/github-release-deb/helpers.sh"

assert_craft_eq '"deb"' '(entryOf (craft { case = "two-systems"; }) "x86_64-linux" "pdfcraft").method' \
  "deb on Linux in a two-system instance"
assert_craft_fails '(craft { case = "two-systems"; }).dotstewardManifest.aarch64-darwin.system' \
  "Failed assertions:" \
  "dotsteward: component pdfcraft does not support darwin (nix.systems contains aarch64-darwin; supported: linux)"
assert_craft_fails '(craft { case = "method-external"; }).dotstewardManifest.x86_64-linux.system' \
  "dotsteward: component deckcraft does not support method external on linux (supported: deb)"
