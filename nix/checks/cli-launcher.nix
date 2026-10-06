# Instance launcher (tests/cli/launcher): template/.dotsteward/cli.sh with
# its flake.lock-keyed cache, state root resolution, DOTSTEWARD_CLI
# override and dirty-tree behaviour. The dirty-tree test builds a tiny flake
# with the real Nix against an isolated store inside the test root, so the
# sandbox needs Nix itself; shellcheck covers the launcher and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-launcher";
  paths = [ "tests/cli/launcher" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
  ];
  postCheck = ''
    shellcheck -x template/.dotsteward/cli.sh tests/cli/launcher/*.sh
  '';
}
