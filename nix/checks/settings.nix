# Settings engine (tests/engines/settings/core): `dotsteward settings`, the
# local-maintained-files engine ported from the original single-file
# engine. The tests run the CLI against synthetic buffers, temporary homes
# and bare git remotes with the toolchain python (tomlkit) on PATH. Then
# shellcheck over the command and the tests, and a byte-compile and lint of
# the engine's Python sources.
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
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.ruff
  ];
  postCheck = ''
    shellcheck -x cli/commands/settings.sh tests/engines/settings/core/*.sh
    PYTHONDONTWRITEBYTECODE=1 python3 -c '
    import ast, pathlib
    for path in sorted(pathlib.Path("engines/local-maintained-files").glob("*.py")):
        ast.parse(path.read_text(encoding="utf-8"), str(path))
    '
    engine=engines/local-maintained-files/local_maintained_files.py
    ruff check --no-cache --quiet --line-length 120 --select E,F,W,B,UP,SIM,RUF "$engine"
    ruff format --no-cache --quiet --check --line-length 120 "$engine"
  '';
}
