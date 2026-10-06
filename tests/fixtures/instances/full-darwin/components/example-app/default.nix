# example-app: installed by Home Manager (method nix), every profile.
{
  lib,
  packages,
  pins,
  dotsteward,
  ...
}:
{
  dotsteward.components.example-app = {
    method = lib.mkDefault "nix";
    supportedMethods = {
      linux = [
        "nix"
        "external"
      ];
      darwin = [ "nix" ];
    };
    install = {
      nix.packages = [ packages.example-app ];
      external.command = "example-app";
    };
    pins.resolvedVersions.example-app =
      dotsteward.lib.pinAt pins "nix_packages.example-app.expected"
        "example-app";
    checks = {
      commands = [ "example-app" ];
      e2e = [
        {
          name = "example-app-hook";
          script = ./hook.sh;
        }
      ];
    };
    bootstrap = {
      backupPaths = [ "~/.config/example-app/state" ];
      snapshots = [
        {
          name = "example-app-state";
          argv = [
            "example-app"
            "dump state"
          ];
          requireCommand = "example-app";
        }
      ];
      prerequisites.apt = [ "example-app-deps" ];
    };
    preflight.detectors.example_detector = {
      argv = [
        "example-app"
        "detect"
      ];
      matchLine = "it's here";
    };
    settingsTargets.example-app = {
      path = "~/.config/example-app/settings.json";
      format = "json";
      createIfMissing = true;
    };
    gate.updatePaths = [ "components/example-app/[^/]+" ];
  };
}
