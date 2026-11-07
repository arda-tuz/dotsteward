# The apt-policy catalog component (tests/nix/components/apt-policy): the E2E hook over a
# stand-in of apt-config and the drop-in it reads. The drop-in on the real apt of each
# Ubuntu release is tests/container (on request). Then shellcheck over the hook and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "component-apt-policy";
  paths = [ "tests/nix/components/apt-policy" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x modules/components/apt-policy/e2e-unattended.sh tests/nix/components/apt-policy/*.sh
  '';
}
