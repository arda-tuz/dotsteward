# herdr: the terminal workspace manager, installed by Home Manager from the
# instance flake input herdr (method nix on Linux and darwin).
#
# The package is inputs.herdr.packages.<system>.herdr. It is read only where
# something installs or reports it (install.nix.packages and
# pins.resolvedVersions), so tools that read the other contract values keep
# working without the input; an instance without the input fails with a
# message that names the line to add to flake.nix (the URL of seed.json).
#
# ~/.config/herdr/config.toml is a normal user file that herdr writes
# itself: Home Manager never links it. The settings engine syncs the entries
# an instance tracks in its buffer (target herdr) and reloads a running
# herdr server after a write. The path is the same on Linux and darwin
# (verified upstream, see README.md).
{
  config,
  lib,
  inputs,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) system;

  seed = lib.importJSON ./seed.json;

  package =
    if !(inputs ? herdr) then
      throw ''
        dotsteward: component herdr needs the instance flake input herdr; add it to the inputs of flake.nix:
          inputs.herdr.url = "${seed.flake_inputs.herdr.url}";
        then run `nix flake lock` and record it in versions.lock.json (`dotsteward pins sync`)''
    else if !(inputs.herdr ? packages.${system}.herdr) then
      throw "dotsteward: component herdr: the instance flake input herdr has no packages.${system}.herdr (check inputs.herdr.url in flake.nix)"
    else
      inputs.herdr.packages.${system}.herdr;

  configPath = "~/.config/herdr/config.toml";

  # The login shell check needs the zsh of the shell component, so it runs
  # only where that component is active: its profiles scope the hook.
  shell =
    config.dotsteward.components.shell or {
      enable = false;
      profiles = null;
    };
in
{
  dotsteward.components.herdr = {
    method = lib.mkDefault "nix";
    supportedMethods = {
      linux = [ "nix" ];
      darwin = [ "nix" ];
    };

    install.nix.packages = [ package ];

    settingsTargets.herdr = {
      path = configPath;
      format = "toml";
      createIfMissing = true;
      createMode = "0644";
      reload = "herdr-server";
    };

    # herdr reads $XDG_CONFIG_HOME/herdr before ~/.config/herdr, and a
    # HERDR_SOCKET_PATH inherited from a pane would address another server.
    reloadHooks.herdr-server = {
      command = [
        "herdr"
        "server"
        "reload-config"
      ];
      timeout = 15;
      env = {
        HOME = "{home}";
        XDG_CONFIG_HOME = "{home}/.config";
      };
      unsetEnv = [ "HERDR_SOCKET_PATH" ];
      requireCommand = "herdr";
      onSuccess = "log";
      onFailure = "silent";
    };

    bootstrap.backupPaths = [ configPath ];

    probes = [
      {
        command = "herdr";
        kind = "presence";
        argv = [ "--version" ];
      }
    ];

    checks = {
      commands = [ "herdr" ];
      e2e = lib.optional shell.enable {
        name = "herdr-login-zsh";
        script = ./e2e-login-zsh.sh;
        phase = "main";
        inherit (shell) profiles;
      };
    };

    pins = {
      flakeInputs = [ "herdr" ];
      rules = [
        {
          kind = "derive";
          to = "nix_packages.herdr.expected";
          from = "flake_inputs.herdr.version";
        }
      ];
      latest = [
        {
          id = "flake_inputs.herdr";
          adapter = "github-release";
          repo = "herdrdev/herdr";
        }
      ];
      resolvedVersions.herdr = package.version;
    };

    docs = ./README.md;
  };
}
