# The dotsteward Nix library (flake output `lib`).
#
# Every library name is exported from the start. Each export is a lazy
# import, so a name whose file a later change adds is harmless until
# something forces it; `nix flake check` never forces this attribute set.
{
  dotsteward,
  nixpkgs,
  home-manager,
}:
let
  inherit (nixpkgs) lib;

  componentsDir = ../modules/components;

  versionText = lib.removeSuffix "\n" (builtins.readFile ../VERSION);
in
lib.fix (
  dsLib:
  let
    args = {
      inherit
        dotsteward
        nixpkgs
        home-manager
        lib
        dsLib
        ;
    };
  in
  {
    # The framework source as a string: the store path with its context for
    # the flake (`self`), the plain absolute path for a checkout (not copied
    # to the store).
    source = toString (dotsteward.outPath or dotsteward);

    mkInstance = import ./mk-instance.nix args;
    mkNpmBundle = import ./npm-bundle.nix args;

    # Catalog components by directory: name -> modules/components/<name>.
    catalog =
      if builtins.pathExists componentsDir then
        lib.mapAttrs (name: _: componentsDir + "/${name}") (
          lib.filterAttrs (_: type: type == "directory") (builtins.readDir componentsDir)
        )
      else
        { };

    config = import ./config.nix args;
    contract = import ./contract.nix args;
    pinAt = import ./pins.nix args;
    platform = import ./platform.nix args;

    # The single version source (VERSION), validated as X.Y.Z.
    version =
      if builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" versionText != null then
        versionText
      else
        throw "dotsteward: invalid VERSION file (expected one line X.Y.Z): '${versionText}'";

    # mkCli :: pkgs -> derivation. The CLI built with the caller's nixpkgs.
    mkCli = import ../nix/packages/dotsteward.nix {
      inherit (dsLib) version;
      src = dotsteward;
      rev = dotsteward.rev or dotsteward.dirtyRev or null;
      narHash = dotsteward.narHash or null;
    };
  }
)
