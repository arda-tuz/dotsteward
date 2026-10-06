# Probe registry (tests/probes): the runner library cli/lib/probes.sh and
# the `dotsteward probes` command against synthetic manifests, lock files
# and the generic stubs, then shellcheck over the runner and its tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "probes";
  paths = [ "tests/probes" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/lib/probes.sh cli/commands/probes.sh tests/probes/*.sh
  '';
}
