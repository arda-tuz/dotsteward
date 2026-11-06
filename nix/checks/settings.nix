# Settings engine (tests/engines/settings/core): `dotsteward settings`, the
# local-maintained-files engine. The tests run the CLI against synthetic
# buffers, temporary homes and bare git remotes with the toolchain python
# (tomlkit) on PATH. Then shellcheck over the command and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "settings";
  paths = [ "tests/engines/settings/core" ];
  # Buffer content whose sha256 legacy-state/base.json records.
  keepShebangs = [ "tests/engines/settings/core/fixtures/buffer/files/alpha-status.sh" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/commands/settings.sh tests/engines/settings/core/*.sh
  '';
}
