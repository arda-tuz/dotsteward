# Pins engine, latest research (tests/engines/pins/latest): `dotsteward pins
# latest` against a synthetic instance that declares every latest adapter,
# run offline in the build sandbox with loopback fakes (an HTTP server over
# fixture files, bare git remotes behind url.insteadOf, the gh and apt-cache
# stubs). Then shellcheck over the tests and a lint and format check of the
# latest runner and its adapters (the rest of the engine is linted by
# checks.pins-check).
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "pins-latest";
  paths = [ "tests/engines/pins/latest" ];
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.ruff
  ];
  postCheck = ''
    shellcheck -x tests/engines/pins/latest/*.sh
    mapfile -t sources < <(find engines/pins/dotsteward_pins/latest -name '*.py' -print | LC_ALL=C sort)
    ((''${#sources[@]} > 0))
    ruff check --no-cache --quiet --line-length 120 --select E,F,W,B,UP,SIM,RUF "''${sources[@]}"
    ruff format --no-cache --quiet --check --line-length 120 "''${sources[@]}"
  '';
}
