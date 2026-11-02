# The craft-anything catalog component: Craft Anything, an application that explains how software works and helps build your own, from the vendor DEB
# that each GitHub release of storytold/craft-anything carries (Apache-2.0). The vendor
# runs no APT repository, so the local APT bridge of the deb method serves
# the newest release and the package updates with plain
# `apt update && apt upgrade` only. Everything else (pin, checks, E2E hook,
# pins declarations) follows modules/core/github-release-deb.nix.
{ lib, ... }:
import ../../core/github-release-deb.nix { inherit lib; } {
  name = "craft-anything";
  repository = "storytold/craft-anything";
  docs = ./README.md;
}
