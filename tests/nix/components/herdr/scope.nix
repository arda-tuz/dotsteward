# Scope of the herdr component tests, layered over
# tests/nix/instance/prelude.nix (lib.mkInstance with constructed inputs).
# An expression evaluated by tests/nix/components/herdr/helpers.sh sees the
# instance prelude and, in addition:
#
#   systems                 the systems of the fixture instance
#   root                    fixtures/instance (herdr enabled, both systems)
#   herdrInput              stand-in for the instance flake input herdr:
#                           packages.<system>.herdr is a package herdr 0.9.3
#                           (evaluated only, never built)
#   herdrInstance ARGS      lib.mkInstance of the fixture with herdrInput;
#                           ARGS as for `instance` of the prelude (inputs are
#                           merged over { herdr = herdrInput; })
#   bareInstance ARGS       the same without the herdr input
#   home INSTANCE SYSTEM    the Home Manager config of the check identity
#   herdrOf INSTANCE SYSTEM dotsteward.components.herdr of that config
#   manifestOf INSTANCE SYSTEM
#                           its manifest without string contexts
{
  lib,
  instance,
  nixpkgsInput,
  repoRoot,
  storeless,
  ...
}:
let
  systems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];

  root = repoRoot + "/tests/nix/components/herdr/fixtures/instance";

  pkgsFor =
    system:
    import nixpkgsInput.outPath {
      inherit system;
      config = { };
      overlays = [ ];
    };

  herdrInput = {
    packages = lib.genAttrs systems (system: {
      herdr = (pkgsFor system).runCommand "herdr-0.9.3" {
        pname = "herdr";
        version = "0.9.3";
      } "mkdir -p $out/bin";
    });
  };

  bareInstance = args: instance ({ inherit root; } // args);

  herdrInstance =
    args:
    bareInstance (
      args
      // {
        inputs = {
          herdr = herdrInput;
        }
        // args.inputs or { };
      }
    );

  home =
    inst: system:
    (inst.lib.mkHome {
      username = "alice";
      homeDirectory = if lib.hasSuffix "-darwin" system then "/Users/alice" else "/home/alice";
      inherit system;
    }).config;
in
{
  inherit
    systems
    root
    herdrInput
    herdrInstance
    bareInstance
    home
    ;

  herdrOf = inst: system: (home inst system).dotsteward.components.herdr;

  manifestOf = inst: system: storeless (home inst system).dotsteward.manifest;
}
