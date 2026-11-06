# Settings engine JSONC reader and validate (tests/engines/settings/jsonc):
# jsonc.strip on its own, JSONC targets with comments or trailing commas
# refused before any write, comment-free JSONC targets written like JSON,
# and `dotsteward settings validate`. Then shellcheck over the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "settings-jsonc";
  paths = [ "tests/engines/settings/jsonc" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tests/engines/settings/jsonc/*.sh
  '';
}
