# Scope of the vscode component tests, layered over
# tests/nix/instance/prelude.nix (lib.mkInstance with constructed inputs).
# An expression evaluated by tests/nix/components/vscode/helpers.sh sees the
# instance prelude and, in addition:
#
#   root                    fixtures/instance (vscode enabled with its
#                           default methods and set_default_editor, both
#                           systems)
#   vscode ARGS             lib.mkInstance of the fixture; ARGS as for
#                           `instance` of the prelude, except that case is a
#                           fixtures/cases/<name>.toml of this directory
#                           (used as config)
#   home INSTANCE SYSTEM [PROFILE]
#                           the Home Manager config of the check identity
#                           (homeIn takes the profile, home uses the
#                           default one)
#   vscodeOf INSTANCE SYSTEM
#                           dotsteward.components.vscode of that config
#   manifestOf INSTANCE SYSTEM
#                           its manifest without string contexts
#   entryOf INSTANCE SYSTEM the manifest's components entry of vscode
#   editorVariables CONFIG  the EDITOR, VISUAL and GIT_EDITOR entries of
#                           home.sessionVariables of CONFIG
{
  lib,
  instance,
  repoRoot,
  storeless,
  ...
}:
let
  dir = repoRoot + "/tests/nix/components/vscode";
  root = dir + "/fixtures/instance";

  vscode =
    args:
    instance (
      {
        inherit root;
      }
      // lib.optionalAttrs (args ? case) { config = dir + "/fixtures/cases/${args.case}.toml"; }
      // removeAttrs args [ "case" ]
    );

  homeIn =
    inst: system: profile:
    (inst.lib.mkHome (
      {
        username = "alice";
        homeDirectory = if lib.hasSuffix "-darwin" system then "/Users/alice" else "/home/alice";
        inherit system;
      }
      // lib.optionalAttrs (profile != null) { inherit profile; }
    )).config;

  home = inst: system: homeIn inst system null;

  manifestOf = inst: system: storeless (home inst system).dotsteward.manifest;
in
{
  inherit
    root
    vscode
    home
    homeIn
    manifestOf
    ;

  vscodeOf = inst: system: (home inst system).dotsteward.components.vscode;

  entryOf =
    inst: system: lib.findFirst (c: c.name == "vscode") null (manifestOf inst system).components;

  editorVariables =
    config:
    lib.filterAttrs (
      name: _:
      lib.elem name [
        "EDITOR"
        "VISUAL"
        "GIT_EDITOR"
      ]
    ) config.home.sessionVariables;
}
