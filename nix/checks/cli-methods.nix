# Install methods (tests/cli/methods): cli/lib/methods.sh and the install
# command against a synthetic instance with the package, download and sudo
# stubs (deb transaction, official-binary, external, phase hooks, adopt
# and check-only modes). No Nix is needed in the sandbox; shellcheck covers
# the engine, the command and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-methods";
  paths = [ "tests/cli/methods" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/lib/methods.sh cli/commands/install.sh tests/cli/methods/*.sh
  '';
}
