# Settings engine JSONC reader and validate (tests/engines/settings/jsonc):
# jsonc.strip on its own, JSONC targets with comments or trailing commas
# refused before any write, comment-free JSONC targets written like JSON,
# and `dotsteward settings validate`. Then shellcheck over the tests, and
# ruff over jsonc.py and lmf_validate.py.
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
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.ruff
  ];
  postCheck = ''
    shellcheck -x tests/engines/settings/jsonc/*.sh
    modules=(engines/local-maintained-files/jsonc.py engines/local-maintained-files/lmf_validate.py)
    ruff check --no-cache --quiet --line-length 120 --select E,F,W,B,UP,SIM,RUF "''${modules[@]}"
    ruff format --no-cache --quiet --check --line-length 120 "''${modules[@]}"
  '';
}
