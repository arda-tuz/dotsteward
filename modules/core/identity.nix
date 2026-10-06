# Identity, state version, profile and the always-on Home Manager settings.
{
  config,
  lib,
  profile,
  username,
  homeDirectory,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg;
  known = builtins.elem profile cfg.profiles.names;
in
{
  options.dotsteward = {
    profile = lib.mkOption {
      type = lib.types.str;
      default = profile;
      readOnly = true;
      description = "The profile of this generation (the mkHome profile argument).";
    };

    profileMode = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "fresh"
          "adopt"
        ]
      );
      default = if known then cfg.profiles.${profile}.mode else null;
      defaultText = lib.literalMD "`[profiles.<profile>] mode` of workstation.toml";
      readOnly = true;
      description = "Mode of the profile: fresh or adopt (D14); null for an unknown profile.";
    };
  };

  config = {
    assertions = [
      {
        assertion = known;
        message = "Unsupported dotsteward profile: ${profile}";
      }
      {
        assertion = config.home.username == username;
        message = "dotsteward: home.username ${config.home.username} differs from the requested username ${username}";
      }
    ];

    home = {
      inherit username homeDirectory;
      stateVersion = cfg.nix.state_version;
      sessionPath = [ "$HOME/.local/bin" ];
    };

    programs.home-manager.enable = true;
  };
}
