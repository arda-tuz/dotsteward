# Rebuild, rollback and login shell (tests/cli/rebuild): the rebuild,
# rollback and login-shell commands against a synthetic instance with a
# fake Nix (host override contract and lock memo, framework override,
# records, dirty-tree refusals, switch ordering with hooks, adoption,
# rollback ABSENT and generation branches, the login shell matrix). Nothing
# is activated for real; shellcheck covers the commands and the
# tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-rebuild";
  paths = [ "tests/cli/rebuild" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/rebuild.sh cli/commands/rollback.sh cli/commands/login-shell.sh \
      tests/cli/rebuild/*.sh
  '';
}
