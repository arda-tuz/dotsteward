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
in
{
  options.dotsteward.agentRules.source = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = if cfg.agent_rules.source == null then null else root + "/${cfg.agent_rules.source}";
    defaultText = lib.literalExpression ''root + "/" + cfg.agent_rules.source'';
    description = "The agent rules file linked to every agent rules target; null links none.";
  };

  config = lib.mkIf (source != null) {
    home.file = lib.listToAttrs (
      map (
        target:
        lib.nameValuePair target.path {
          inherit source;
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
