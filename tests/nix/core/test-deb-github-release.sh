# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The contract of install.deb.githubRelease: the GitHub repository whose
# newest release carries the DEBs, the asset file name per dpkg
# architecture with one {version} placeholder, and the checksum file of the
# release. It defaults to null; the checksum file defaults to
# SHA256SUMS.txt. A repository that is not owner/name, an empty asset map,
# an asset without {version} or with a path, and a checksum file name with a
# path are refused at evaluation.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# release_of RELEASE: the evaluated githubRelease of example-app with RELEASE.
release_of() {
  printf '(homeOf { modules = componentModules ++ [ { dotsteward.components.example-app.install.deb.githubRelease = (%s); } ]; }).dotsteward.components.example-app.install.deb.githubRelease' "$1"
}
release_with() {
  printf '{ repository = "example-org/example-app"; assets.amd64 = "example-app-{version}-linux-x86_64.deb"; } // %s' "$1"
}

assert_core_eq 'null' '(homeOf { modules = componentModules; }).dotsteward.components.example-app.install.deb.githubRelease'
assert_core_eq '{"repository": "example-org/example-app", "assets": {"amd64": "example-app-{version}-linux-x86_64.deb"}, "checksums": "SHA256SUMS.txt"}' \
  "$(release_of "$(release_with '{ }')")" "defaults"
assert_core_eq '"checksums.txt"' "($(release_of "$(release_with '{ checksums = "checksums.txt"; }')")).checksums"

assert_core_fails "$(release_of "$(release_with '{ repository = "example-app"; }')")" "GitHub repository"
assert_core_fails "$(release_of "$(release_with '{ repository = "https://github.com/example-org/example-app"; }')")" "GitHub repository"
assert_core_fails "$(release_of "$(release_with '{ assets = { }; }')")" "at least one asset"
assert_core_fails "$(release_of "$(release_with '{ assets.amd64 = "example-app-linux-x86_64.deb"; }')")" "{version}"
assert_core_fails "$(release_of "$(release_with '{ assets.amd64 = "dist/example-app-{version}.deb"; }')")" "{version}"
assert_core_fails "$(release_of "$(release_with '{ checksums = "../SHA256SUMS.txt"; }')")" "release asset name"
