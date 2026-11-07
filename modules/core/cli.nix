# The dotsteward CLI in the generation, and the local-maintained-files alias:
# `dotsteward settings` with the defaults of this generation baked in.
#
# The alias passes --targets-file (the settings targets of the active
# components, rendered for the platform), --repo-default (the expanded
# instance.checkout) and --state-dir-default (<state.root>/
# local-maintained-files, expanded by the shell at run time). The engine
# uses the defaults last: after the environment
# (DOTSTEWARD_INSTANCE and DOTSTEWARD_STATE_ROOT, plus DOTFILES_ROOT and
# DOTFILES_STATE_ROOT with [compat] legacy_env) and instance discovery.
# Arguments given to the alias come last, so an explicit --repo or
# --state-dir wins.
{
  config,
  lib,
  pkgs,
  profile,
  homeDirectory,
  packages,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg system;
  helpers = import ./helpers.nix { inherit lib; };
  cli = config.dotsteward.cli;

  platform = dotsteward.lib.platform.platformOf system;
  active = lib.filter (
    { name, component }: helpers.isActive profile platform (dotsteward.tags or [ ]) name component
  ) (helpers.enabled cfg config.dotsteward.components);

  cliPackage = packages.dotsteward or (dotsteward.lib.mkCli pkgs);

  # Every target of the instance, each saying whether this generation has its component:
  # a buffer entry of a component this machine leaves out waits, it is no unknown target.
  enabled = helpers.enabled cfg config.dotsteward.components;
  activeNames = map ({ name, ... }: name) active;
  settingsTargets = lib.mapAttrs (_: target: target // { active = lib.elem target.component activeNames; }) (
    helpers.settingsTargets system dotsteward.lib.platform enabled
  );

  targetsFile = pkgs.writeText "dotsteward-settings-targets.json" (
    builtins.toJSON {
      schema_version = 1;
      targets = settingsTargets;
      reload_hooks = helpers.reloadHooks enabled;
    }
  );

  stateRoot = helpers.shellWord "state.root" homeDirectory cfg.state.root;

  defaults = [
    "--targets-file"
    (lib.escapeShellArg "${targetsFile}")
  ]
  ++ lib.optionals (cfg.instance.checkout != null) [
    "--repo-default"
    (helpers.shellWord "instance.checkout" homeDirectory cfg.instance.checkout)
  ]
  ++ [
    "--state-dir-default"
    "${stateRoot}/local-maintained-files"
  ];

  alias = pkgs.writeTextFile {
    name = "local-maintained-files";
    destination = "/bin/local-maintained-files";
    executable = true;
    text = ''
      #!${pkgs.runtimeShell}
      # local-maintained-files: dotsteward settings with the defaults of this
      # generation; explicit arguments, the environment and instance
      # discovery take precedence.
      exec ${lib.getExe' cliPackage "dotsteward"} settings ${lib.concatStringsSep " " defaults} "$@"
    '';
    checkPhase = ''
      ${pkgs.stdenv.shellDryRun} "$target"
    '';
    passthru = { inherit targetsFile; };
    meta.mainProgram = "local-maintained-files";
  };
in
{
  options.dotsteward.cli = {
    alias = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install local-maintained-files, dotsteward settings with this generation's defaults.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = cliPackage;
      defaultText = lib.literalExpression "packages.dotsteward";
      readOnly = true;
      description = "The dotsteward CLI installed in the generation.";
    };

    settingsTargets = lib.mkOption {
      internal = true;
      readOnly = true;
      type = lib.types.attrsOf lib.types.anything;
      default = settingsTargets;
      description = "The settings targets of this generation's targets file, each with active.";
    };

    aliasPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = if cli.alias then alias else null;
      defaultText = lib.literalMD "the alias when `dotsteward.cli.alias` is true, else null";
      readOnly = true;
      internal = true;
      description = ''
        The local-maintained-files alias (passthru.targetsFile: its settings
        targets). Its targets depend on the profile, so it is not part of the
        manifest.
      '';
    };
  };

  config = {
    home.packages = [ cliPackage ] ++ lib.optional cli.alias alias;

    dotsteward.core.commands = [ "jq" ] ++ lib.optional cli.alias "local-maintained-files";
  };
}
