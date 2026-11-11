# The observer: systemd user units that start `dotsteward observe` for the instance
# checkout when the system packages change outside dotsteward (an apt run of the owner,
# unattended-upgrades, a software center).
#
#   dotsteward-observe.path     PathChanged= on /var/lib/dpkg/status, which dpkg writes
#                               at the end of every run, whatever program drove it
#   dotsteward-observe.service  the observer; it waits until dpkg and apt settled. Also
#                               wanted by default.target: the user manager watches
#                               nothing while nobody is logged in, so a login catches up
#
# Both unit files and their default.target.wants links are managed links of core (E2E
# checks them, rollback removes them); core:observer of E2E checks that the user manager
# runs the path unit. The service is Type=exec, so a login or an activation never waits
# for it. A pending mark (exit 3) and a record that waits for the network (exit 6) are no
# failures. Linux only: macOS has neither dpkg nor systemd. Without an instance checkout
# (no instance.name) there is no instance to observe, and no units.
{
  config,
  lib,
  pkgs,
  homeDirectory,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg;
  helpers = import ./helpers.nix { inherit lib; };
  observer = config.dotsteward.observer;
  linux = pkgs.stdenv.hostPlatform.isLinux;
  checkout = cfg.instance.checkout;

  script = pkgs.writeShellScript "dotsteward-observe" ''
    exec ${lib.getExe' config.dotsteward.cli.package "dotsteward"} --instance ${
      helpers.shellWord "instance.checkout" homeDirectory checkout
    } observe "$@"
  '';
in
{
  options.dotsteward.observer = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = linux && checkout != null;
      defaultText = lib.literalMD "true on Linux when the instance has a checkout";
      description = "Start `dotsteward observe` from a systemd user path unit on the dpkg status file.";
    };

    script = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = if observer.enable then script else null;
      defaultText = lib.literalMD "the script of the service when the observer is on, else null";
      readOnly = true;
      internal = true;
      description = "The script the observer service runs.";
    };
  };

  config = lib.mkIf observer.enable {
    assertions = [
      {
        assertion = linux;
        message = "dotsteward.observer.enable: the observer needs dpkg and systemd (Linux)";
      }
      {
        assertion = checkout != null;
        message = "dotsteward.observer.enable: the observer needs the instance checkout (instance.name or instance.checkout)";
      }
    ];

    # E2E checks that the units resolve; rollback removes them.
    dotsteward.core.managedLinks = [
      "~/.config/systemd/user/dotsteward-observe.path"
      "~/.config/systemd/user/dotsteward-observe.service"
      "~/.config/systemd/user/default.target.wants/dotsteward-observe.path"
      "~/.config/systemd/user/default.target.wants/dotsteward-observe.service"
    ];

    systemd.user.paths.dotsteward-observe = {
      Unit.Description = "Notice system package changes for dotsteward";
      Path = {
        PathChanged = "/var/lib/dpkg/status";
        Unit = "dotsteward-observe.service";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.dotsteward-observe = {
      Unit = {
        Description = "Check and record the system packages changed outside dotsteward";
        # An apt run writes the status file many times a second; a start limit would stop
        # the path unit for good (unit-start-limit-hit).
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "exec";
        ExecStart = "${script}";
        SuccessExitStatus = "3 6";
        Environment = [ "PATH=${config.home.profileDirectory}/bin:/usr/local/bin:/usr/bin:/bin" ];
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
