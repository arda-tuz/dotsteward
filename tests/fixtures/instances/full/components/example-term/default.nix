# example-term: official-binary on Linux by default, nix on darwin; reads its
# [components.example-term].options.
{
  config,
  lib,
  packages,
  profile,
  ...
}:
let
  component = config.dotsteward.components.example-term;
  active = component.profiles == null || lib.elem profile component.profiles;
in
{
  dotsteward.components.example-term = {
    method = lib.mkDefault "official-binary";
    supportedMethods = {
      linux = [
        "official-binary"
        "nix"
      ];
      darwin = [ "nix" ];
    };
    install = {
      nix.packages = [ packages.example-term ];
      official-binary = {
        pin = "agent_tools.example-term";
        asset = {
          linux = "example-term-{version}-x86_64-linux.tar.gz";
          darwin = "example-term-{version}-aarch64-darwin.tar.gz";
        };
        member = "example-term";
        dest = "~/.local/bin/example-term";
        versionArgv = [ "--version" ];
        versionRegex = "example-term ([0-9.]+)";
        policy = "at-least";
        verify = "sha256";
      };
    };
    agentRulesTargets = [ { path = ".example-term/AGENTS.md"; } ];
    rollback.managedLinks = [ "~/.example-term/AGENTS.md" ];
    pins.resolvedVersions.example-term = "2.0.0";
    settingsTargets.example-term = {
      path = {
        linux = "~/.config/example-term/config.toml";
        darwin = "~/Library/Application Support/example-term/config.toml";
      };
      format = "toml";
      createIfMissing = true;
    };
  };

  # Home files may depend on the profile and on the options: the
  # greeting is written only in the profiles the component is active in.
  home.file.".example-term/greeting" = lib.mkIf active {
    text = component.options.greeting + "\n";
  };
}
