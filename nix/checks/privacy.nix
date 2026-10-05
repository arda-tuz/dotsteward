# Privacy scanner (tests/privacy, including the six-leak drill on the scanner
# side), then the generic scan of the framework source itself, which in the
# sandbox has no .git and is listed with find.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "privacy";
  paths = [ "tests/privacy" ];
  postCheck = ''
    ./cli/dotsteward scan --tree --redact
  '';
}
