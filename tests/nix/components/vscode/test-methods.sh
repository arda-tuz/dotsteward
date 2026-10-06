# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154 # Nix expressions in single quotes; DS_* variables come from the harness
# The methods of vscode: deb (Linux default), app-archive (darwin default)
# and external (both), selected with [components.vscode] method and
# method_by_platform. The pins declarations follow the methods of the
# platforms in nix.systems, so an instance lock needs only the pins its
# methods read; deb on darwin and app-archive on Linux are refused.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

# pins_of CASE SYSTEM: the at paths of the vscode rules and the ids of its
# latest declarations in the manifest of SYSTEM.
pins_of() {
  vscode_json "let
    m = manifestOf (vscode { case = \"$1\"; }) \"$2\";
    own = lib.filter (e: e.component == \"vscode\");
  in { rules = map (r: r.at) (own m.pins.rules); latest = map (l: l.id) (own m.pins.latest); }" | jq -cS .
}

# external on both platforms: code on PATH, no floor and no pins.
for system in x86_64-linux aarch64-darwin; do
  assert_vscode_eq '{
    "method": "external",
    "install": { "command": "code", "versionArgv": ["--version"], "minimum": null }
  }' "let e = entryOf (vscode { case = \"method-external\"; }) \"$system\"; in { inherit (e) method install; }" \
    "external install block on $system"
  assert_eq '{"latest":[],"rules":[]}' "$(pins_of method-external "$system")" "external pins on $system"
done

# method_by_platform: deb on Linux, external on darwin; both manifests
# declare only the Linux pin.
assert_vscode_eq '["deb","external"]' 'let i = vscode { case = "by-platform"; }; in
  [ (entryOf i "x86_64-linux").method (entryOf i "aarch64-darwin").method ]' "method_by_platform"
for system in x86_64-linux aarch64-darwin; do
  assert_eq '{"latest":["desktop_packages.vscode"],"rules":["desktop_packages.vscode"]}' \
    "$(pins_of by-platform "$system")" "deb-only pins on $system"
done

# A Linux-only instance declares only the Linux pin.
assert_eq '{"latest":["desktop_packages.vscode"],"rules":["desktop_packages.vscode"]}' \
  "$(pins_of linux-only x86_64-linux)" "pins of a Linux-only instance"

# The default methods declare both pins in both manifests.
for system in x86_64-linux aarch64-darwin; do
  assert_eq '{"latest":["desktop_packages.vscode","desktop_packages.vscode-darwin-arm64"],"rules":["desktop_packages.vscode","desktop_packages.vscode-darwin-arm64"]}' \
    "$(pins_of editor-absent "$system")" "default pins on $system"
done

# deb on darwin and app-archive on Linux are refused by the supported-methods
# assertion; the other system still evaluates.
assert_vscode_eq '"deb"' '(entryOf (vscode { case = "darwin-deb"; }) "x86_64-linux").method' \
  "deb on Linux in a two-system instance"
assert_vscode_fails '(vscode { case = "darwin-deb"; }).dotstewardManifest.aarch64-darwin.system' \
  "Failed assertions:" \
  "dotsteward: component vscode does not support method deb on darwin (supported: app-archive, external)"
assert_vscode_fails '(vscode { case = "linux-app-archive"; }).dotstewardManifest.x86_64-linux.system' \
  "Failed assertions:" \
  "dotsteward: component vscode does not support method app-archive on linux (supported: deb, external)"

# The settings target does not depend on the method.
assert_vscode_eq 'true' 'let
  target = c: s: (manifestOf (vscode { case = c; }) s).settings_targets;
in target "method-external" "x86_64-linux" == target "editor-absent" "x86_64-linux"
  && target "method-external" "aarch64-darwin" == target "editor-absent" "aarch64-darwin"' \
  "method-independent settings target"
