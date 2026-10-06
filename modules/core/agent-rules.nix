# The agent rules file: one source linked to every agentRulesTargets entry
# of the active components, so all targets share one store file.
{
  config,
  lib,
  profile,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg root system;
  helpers = import ./helpers.nix { inherit lib; };

  platform = dotsteward.lib.platform.platformOf system;
  source = config.dotsteward.agentRules.source;
  targets = lib.concatMap ({ component, ... }: component.agentRulesTargets) (
    lib.filter ({ component, ... }: helpers.isActive profile platform component) (
      helpers.enabled cfg config.dotsteward.components
    )
  );

  # The source copied into a store path of its own, whatever form `root`
  # takes. mkInstance passes root as a store path string with context
  # ("${self}"), which Home Manager would link as is, into the whole
  # instance source: every commit of the instance would then change the
  # generation. The name is the one Home Manager gives a path source, so a
  # path root yields the same store path.
  storePath =
    if source == null then
      null
    else
      builtins.path {
        path = source;
        name = config.lib.strings.storeFileName (
          builtins.unsafeDiscardStringContext (baseNameOf (toString source))
        );
      };
in
{
  options.dotsteward.agentRules = {
    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if cfg.agent_rules.source == null then null else root + "/${cfg.agent_rules.source}";
      defaultText = lib.literalExpression ''root + "/" + cfg.agent_rules.source'';
      description = "The agent rules file linked to every agent rules target; null links none.";
    };

    storePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = storePath;
      defaultText = lib.literalMD "the store copy of `dotsteward.agentRules.source`";
      readOnly = true;
      internal = true;
      description = ''
        The store file every agent rules target links to (the manifest's
        agent_rules.source, which E2E compares byte for byte).
      '';
    };
  };

  config = lib.mkIf (source != null) {
    home.file = lib.listToAttrs (
      map (
        target:
        lib.nameValuePair target.path {
          source = storePath;
          inherit (target) force;
        }
      ) targets
    );

    assertions = [
      {
        assertion = targets == [ ] || builtins.pathExists source;
        message = "dotsteward: agent rules source ${toString source} does not exist";
      }
    ];
  };
}
