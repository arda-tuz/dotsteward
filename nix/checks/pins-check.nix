# Pins engine, check and sync (tests/engines/pins/check): `dotsteward pins
# check|sync` and `dotsteward sync` against a synthetic instance that
# declares every rule kind, run offline in the build sandbox (stub nix for
# --nix and the mirror evaluation). Then shellcheck over the commands and
# the tests, and a lint and format check of the engine's Python sources
# (the latest runner and its adapters are linted by checks.pins-latest).
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "pins-check";
  paths = [ "tests/engines/pins/check" ];
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.ruff
  ];
  postCheck = ''
    shellcheck -x cli/commands/pins.sh cli/commands/sync.sh tests/engines/pins/check/*.sh
    engine=engines/pins/dotsteward_pins
    mapfile -t sources < <(find "$engine" -path "$engine/latest" -prune -o -name '*.py' -print | LC_ALL=C sort)
    ruff check --no-cache --quiet --line-length 120 --select E,F,W,B,UP,SIM,RUF "''${sources[@]}"
    ruff format --no-cache --quiet --check --line-length 120 "''${sources[@]}"
  '';
}
