# shell: zsh with the starship prompt, installed by Home Manager (method nix
# on Linux and darwin).
#
# - zsh comes from the locked nixpkgs; starship is packages.<system>.starship
#   of the instance (package.nix, starship-package.nix: built from the
#   pinned release tag). Both are in home.packages; programs.starship uses
#   the same starship with every shell integration off, because the
#   starship-init block of ~/.zshrc initializes the prompt.
# - ~/.zshrc is dotsteward.shell.zshrc.text, rendered by core from ordered
#   blocks; the defaults and the plugin options are in zshrc.nix. Home
#   Manager's programs.zsh stays off: it would write its own ~/.zshrc.
# - starship.toml is written by Home Manager from programs.starship.settings,
#   which the instance sets (home.nix); without settings there is no file.
# - The login shell (core: dotsteward.loginShell.path) is the zsh of the
#   Nix profile; stage-0 backs up the shells file before adding it.
#
# The contract values never depend on the profile; with profiles set,
# only the packages, ~/.zshrc and programs.starship are left out of the
# other profiles.
{
  config,
  lib,
  pkgs,
  packages,
  profile,
  dotsteward,
  ...
}:
let
  helpers = import ../../core/helpers.nix { inherit lib; };

  component = config.dotsteward.components.shell;
  active = helpers.isActive profile (dotsteward.lib.platform.platformOf dotsteward.system) component;

  starship = config.programs.starship;
  starshipPackage = packages.starship;

  # Home Manager writes starship.toml only for settings or presets.
  hasStarshipConfig = starship.settings != { } || starship.presets != [ ];
  home = config.home.homeDirectory;
  starshipConfigLink =
    if lib.hasPrefix "${home}/" starship.configPath then
      "~" + lib.removePrefix home starship.configPath
    else
      starship.configPath;
in
{
  imports = [ ./zshrc.nix ];

  dotsteward.components.shell = {
    method = lib.mkDefault "nix";
    supportedMethods = {
      linux = [ "nix" ];
      darwin = [ "nix" ];
    };

    install.nix.packages = [
      pkgs.zsh
      starshipPackage
    ];

    probes = [
      {
        command = "starship";
        kind = "presence";
        argv = [ "--version" ];
      }
    ];

    checks.commands = [
      "zsh"
      "starship"
    ];

    bootstrap.backupPaths = [
      "~/.zshrc"
      "/etc/shells"
    ];

    rollback.managedLinks = [ "~/.zshrc" ] ++ lib.optional hasStarshipConfig starshipConfigLink;

    pins = {
      latest = [
        {
          id = "nix_packages.starship";
          adapter = "github-release";
          repo = "starship/starship";
        }
      ];
      resolvedVersions = {
        zsh = pkgs.zsh.version;
        starship = starshipPackage.version;
      };
    };

    docs = ./README.md;
  };

  home.file.".zshrc" = lib.mkIf active { inherit (config.dotsteward.shell.zshrc) text; };

  programs.starship = {
    enable = lib.mkIf active true;
    package = starshipPackage;
    enableBashIntegration = false;
    enableZshIntegration = false;
    enableFishIntegration = false;
    enableIonIntegration = false;
    enableNushellIntegration = false;
  };
}
