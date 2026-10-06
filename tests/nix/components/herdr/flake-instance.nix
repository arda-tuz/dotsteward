# The herdr fixture instance evaluated inside the framework flake (used by
# nix/checks/component-herdr.nix): lib.mkInstance with the framework's own
# self, nixpkgs and home-manager, the instance root
# fixtures/instance as a store path, and a stand-in for the instance flake
# input herdr whose herdr command records every call (argv and the
# environment the settings reload hook controls) in $HERDR_CALL_LOG.
#
#   { instance, herdr }
{
  self,
  dsLib,
  pkgs,
}:
let
  root = "${./fixtures/instance}";

  herdr =
    pkgs.writeTextFile {
      name = "herdr-0.9.3";
      destination = "/bin/herdr";
      executable = true;
      text = ''
        #!${pkgs.runtimeShell}
        # Stand-in herdr: records the call, prints a version.
        if [ -n "''${HERDR_CALL_LOG:-}" ]; then
          printf 'herdr %s\n' "$*" >>"$HERDR_CALL_LOG"
          printf 'env HOME=%s XDG_CONFIG_HOME=%s HERDR_SOCKET_PATH=%s\n' \
            "''${HOME-<unset>}" "''${XDG_CONFIG_HOME-<unset>}" "''${HERDR_SOCKET_PATH-<unset>}" >>"$HERDR_CALL_LOG"
        fi
        if [ "''${1:-}" = --version ]; then
          echo "herdr 0.9.3"
        fi
      '';
    }
    // {
      pname = "herdr";
      version = "0.9.3";
    };
in
{
  inherit herdr;

  instance = dsLib.mkInstance {
    inherit root;
    inputs = {
      self.outPath = root;
      inherit (self.inputs) nixpkgs home-manager;
      dotsteward = self;
      herdr.packages.${pkgs.stdenv.hostPlatform.system}.herdr = herdr;
    };
  };
}
