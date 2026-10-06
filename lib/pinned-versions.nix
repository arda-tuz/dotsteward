# lib.pinnedVersions of one system: the versions the instance's Nix
# evaluation resolves, compared with versions.lock.json nix_packages by
# `pins check --nix` (rule nix-resolved).
#
#   pinnedVersions { pkgs, cfg, components } -> { <lock key> = "<version>"; }
#
# The union of
#   - pins.resolvedVersions of every enabled component (components is the
#     Home Manager value of dotsteward.components), in [components] order;
#   - core: tomlkit, the Python library of the CLI engines (F8);
#   - [pins] nixpkgs_versions: lock key -> nixpkgs attribute path, for
#     plain nixpkgs packages.
# A key declared twice is an error naming both sources. Versions are
# evaluated lazily, so a missing lock key surfaces as the pinAt error of the
# component that reads it.
{ lib, ... }:
let
  helpers = import ../modules/core/helpers.nix { inherit lib; };

  # Adds { key = value; } of SOURCE to ACC ({ key = { source; value; }; }).
  add =
    acc: source: values:
    lib.foldl' (
      acc: key:
      if acc ? ${key} then
        throw "dotsteward: pinned version ${key} is declared twice (by ${acc.${key}.source} and by ${source})"
      else
        acc
        // {
          ${key} = {
            inherit source;
            value = values.${key};
          };
        }
    ) acc (lib.attrNames values);

  nixpkgsVersion =
    pkgs: key: attrPath:
    let
      where = "dotsteward: [pins] nixpkgs_versions.${key}";
      value = lib.attrByPath (lib.splitString "." attrPath) null pkgs;
    in
    if value == null then
      throw "${where}: nixpkgs has no attribute ${attrPath}"
    else if !(lib.isDerivation value) || !(value ? version) then
      throw "${where}: nixpkgs attribute ${attrPath} is not a package with a version"
    else
      value.version;
in
{
  pkgs,
  cfg,
  components,
}:
let
  fromComponents = lib.foldl' (
    acc:
    { name, component }:
    add acc "component ${name}" component.pins.resolvedVersions
  ) { } (helpers.enabled cfg components);

  withCore = add fromComponents "core" { tomlkit = pkgs.python3Packages.tomlkit.version; };

  all = add withCore "[pins] nixpkgs_versions" (
    lib.mapAttrs (nixpkgsVersion pkgs) cfg.pins.nixpkgs_versions
  );
in
lib.mapAttrs (_: entry: entry.value) all
