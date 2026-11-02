# The deckcraft catalog component: DeckCraft, a presentation and slide show application, from the vendor DEB
# that each GitHub release of storytold/deckcraft carries (Apache-2.0). The vendor
# runs no APT repository, so the local APT bridge of the deb method serves
# the newest release and the package updates with plain
# `apt update && apt upgrade` only. Everything else (pin, checks, E2E hook,
# pins declarations) follows modules/core/github-release-deb.nix.
{ lib, ... }:
import ../../core/github-release-deb.nix { inherit lib; } {
  name = "deckcraft";
  repository = "storytold/deckcraft";
  docs = ./README.md;
}
