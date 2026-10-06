# CLI library (tests/cli/lib) and configuration reader (tests/cli/config):
# the generic bash library, the Linux platform layer, the Python
# workstation.toml reader and its DS_* exporter, and the Nix parity test,
# which evaluates lib/config.nix with nix-instantiate against an isolated
# store (as checks.nix-lib does), so the sandbox needs Nix and the nixpkgs
# source. Then shellcheck over the library and its tests, and a byte-compile
# of the Python package.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-cli-lib-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
    '';
  };
in
cli.mkTestCheck {
  name = "cli-lib";
  paths = [
    "tests/cli/lib"
    "tests/cli/config"
  ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    shellcheck -x cli/lib/lib.sh cli/lib/config.sh cli/lib/platform-linux.sh \
      tests/cli/lib/*.sh tests/cli/config/*.sh
    PYTHONDONTWRITEBYTECODE=1 python3 -c '
    import ast, pathlib
    for path in sorted(pathlib.Path("cli/python").rglob("*.py")):
        ast.parse(path.read_text(encoding="utf-8"), str(path))
    '

    # The package: the reader runs from the installed tree with the
    # package's catalog.json (the package has no modules/ directory), which
    # lists the framework's catalog directories.
    share=${cli}/share/dotsteward
    test ! -e "$share/modules"
    expected='[]'
    if [[ -d modules/components ]]; then
      expected=$(find modules/components -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
        LC_ALL=C sort | jq -R . | jq -cs .)
    fi
    test "$(jq -c . "$share/catalog.json")" = "$expected"
    instance=$(mktemp -d)
    cp tests/nix/lib/fixtures/valid/minimal.toml "$instance/workstation.toml"
    order=$(cd "$instance" && PYTHONPATH=$share/cli/python ${cli.passthru.python.interpreter} -s -P \
      -m dotsteward_cli.config resolve | jq -c '[.components.order[]] | sort')
    test "$order" = "$expected"
  '';
}
