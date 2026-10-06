# starship built from the pinned release tag on the locked nixpkgs toolchain.
#
# The locked nixpkgs starship with only version, source, vendored cargo
# dependencies and doCheck replaced, so the store path depends on the lock
# values alone. The lock values (versions.lock.json):
#   nix_packages.starship.expected            release version (tag v<expected>)
#   nix_packages.starship.source_nix_sha256   SRI hash of the source tree
#   nix_packages.starship.cargo_nix_sha256    SRI hash of the vendored crates
{
  pkgs,
  pins,
  dsLib,
}:
let
  pin = key: dsLib.pinAt pins "nix_packages.starship.${key}" "shell";
in
pkgs.starship.overrideAttrs (_old: rec {
  version = pin "expected";
  src = pkgs.fetchFromGitHub {
    owner = "starship";
    repo = "starship";
    tag = "v${version}";
    hash = pin "source_nix_sha256";
  };
  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    inherit src;
    hash = pin "cargo_nix_sha256";
  };
  # A source build would otherwise rebuild and run the upstream test suite on
  # every nixpkgs update; the version and the binary are checked by the
  # component check and the E2E probes instead.
  doCheck = false;
})
