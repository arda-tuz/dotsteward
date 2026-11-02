# Scope of the github-release-deb component tests, layered over
# tests/nix/instance/prelude.nix (lib.mkInstance with constructed inputs).
# An expression evaluated by tests/nix/components/github-release-deb/helpers.sh
# sees the instance prelude and, in addition:
#
#   names                   the catalog components built by
#                           modules/core/github-release-deb.nix
#   root                    fixtures/instance (all of them enabled, Linux)
#   craft ARGS              lib.mkInstance of the fixture; ARGS as for
#                           `instance` of the prelude, except that case is a
#                           fixtures/cases/<name>.toml of this directory
#   home INSTANCE SYSTEM    the Home Manager config of the check identity
#   componentOf INSTANCE SYSTEM NAME
#                           dotsteward.components.NAME of that config
#   manifestOf INSTANCE SYSTEM
#                           its manifest without string contexts
#   entryOf INSTANCE SYSTEM NAME
#                           the manifest's components entry of NAME
{
  lib,
  instance,
  repoRoot,
  storeless,
  ...
}:
let
  dir = repoRoot + "/tests/nix/components/github-release-deb";
  root = dir + "/fixtures/instance";

  craft =
    args:
    instance (
      {
        inherit root;
      }
      // lib.optionalAttrs (args ? case) { config = dir + "/fixtures/cases/${args.case}.toml"; }
      // removeAttrs args [ "case" ]
    );

  home =
    inst: system:
    (inst.lib.mkHome {
      username = "alice";
      homeDirectory = if lib.hasSuffix "-darwin" system then "/Users/alice" else "/home/alice";
      inherit system;
    }).config;

  manifestOf = inst: system: storeless (home inst system).dotsteward.manifest;
in
{
  inherit
    root
    craft
    home
    manifestOf
    ;

  names = [
    "pdfcraft"
    "gridcraft"
    "wordcraft"
    "deckcraft"
    "craft-anything"
  ];

  componentOf =
    inst: system: name:
    (home inst system).dotsteward.components.${name};

  entryOf =
    inst: system: name:
    lib.findFirst (c: c.name == name) null (manifestOf inst system).components;
}
