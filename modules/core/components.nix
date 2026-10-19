# The component contract option, core's own contributions, the aggregated
# managed links and the nix install method.
#
# A component is active in this generation when it is enabled, its profiles
# are null or contain the profile, and it supports the platform. Active
# components whose resolved method is nix get install.nix.packages in
# home.packages; the other methods run outside Home Manager (cli methods).
# Active pypi components with install.pypi.pathAppend add the ~/.zshrc block
# pypi-path-<name> (order 90), which appends the bin directory of their
# virtual environment to PATH once, after every other entry, so its
# interpreter and pip never shadow the user's own.
{
  config,
  lib,
  profile,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg system;
  inherit (dotsteward.lib) contract;
  helpers = import ./helpers.nix { inherit lib; };

  platform = dotsteward.lib.platform.platformOf system;
  enabled = helpers.enabled cfg config.dotsteward.components;
  active = lib.filter ({ component, ... }: helpers.isActive profile platform component) enabled;

  pypiPathBlock =
    name: venv:
    let
      bin = "$HOME/${lib.removePrefix "~/" venv}/bin";
    in
    ''
      # ${name} (pypi): the commands of its virtual environment, after every other PATH entry
      if [[ ":$PATH:" != *":${bin}:"* ]]; then
        export PATH="$PATH:${bin}"
      fi
    '';
  pypiPathAppended = lib.filter (
    { component, ... }: component.method == "pypi" && component.install.pypi.pathAppend
  ) active;

  list =
    type: description:
    lib.mkOption {
      type = lib.types.listOf type;
      default = [ ];
      inherit description;
    };
in
{
  options.dotsteward = {
    components = contract.componentsOption;

    core = lib.mkOption {
      internal = true;
      type = lib.types.submodule {
        options = {
          managedLinks = list contract.types.hostPath "Managed links of core.";
          backupPaths = list contract.types.hostPath "Backup paths of core.";
          commands = list lib.types.str "Commands E2E requires for core.";
        };
      };
      default = { };
      description = "Core's own contributions, reported as component core.";
    };

    managedLinks = lib.mkOption {
      type = lib.types.listOf contract.types.hostPath;
      description = ''
        Home Manager links that rollback removes and E2E checks: core's, then
        those of the enabled components in [components] order, then any an
        instance module adds.
      '';
    };
  };

  config = {
    dotsteward.managedLinks =
      config.dotsteward.core.managedLinks
      ++ lib.concatMap ({ component, ... }: component.rollback.managedLinks) enabled;

    home.packages = lib.concatMap ({ component, ... }: component.install.nix.packages) (
      lib.filter ({ component, ... }: component.method == "nix") active
    );

    dotsteward.shell.zshrc.blocks = lib.listToAttrs (
      map (
        { name, component }:
        lib.nameValuePair "pypi-path-${name}" {
          order = 90;
          text = pypiPathBlock name component.install.pypi.venv;
        }
      ) pypiPathAppended
    );
  };
}
