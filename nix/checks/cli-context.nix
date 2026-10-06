# Context and doctor (tests/cli/context): `dotsteward context --json`, its
# schema (validated with python jsonschema), `dotsteward doctor` and its
# --redact report, run against synthetic instances with the toolchain python
# on PATH. Then shellcheck over the commands and the tests, a lint of the
# Python modules, and a run of the packaged CLI, which must find its schema,
# catalog and VERSION in the installed tree.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  jsonschemaPython = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-cli-context-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_JSONSCHEMA_PYTHON=${jsonschemaPython.interpreter}
    '';
  };
in
cli.mkTestCheck {
  name = "cli-context";
  paths = [ "tests/cli/context" ];
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.ruff
    testEnv
  ];
  postCheck = ''
    shellcheck -x cli/commands/context.sh cli/commands/doctor.sh tests/cli/context/*.sh
    modules="cli/python/dotsteward_cli/context.py cli/python/dotsteward_cli/doctor.py"
    PYTHONDONTWRITEBYTECODE=1 python3 -c '
    import ast, pathlib, sys
    for name in sys.argv[1:]:
        path = pathlib.Path(name)
        ast.parse(path.read_text(encoding="utf-8"), str(path))
    ' $modules
    ruff check --no-cache --quiet --line-length 120 --select E,F,W,B,UP,SIM,RUF $modules
    ruff format --no-cache --quiet --check --line-length 120 $modules

    # The packaged CLI: context and doctor from the installed tree, with an
    # environment that holds only the instance and the runtime identity.
    instance=$(mktemp -d)
    cp tests/nix/lib/fixtures/valid/minimal.toml "$instance/workstation.toml"
    home=$(mktemp -d)
    env -i HOME="$home" USER=alice DOTSTEWARD_INSTANCE="$instance" \
      ${cli}/bin/dotsteward context --json >context.json
    ${jsonschemaPython.interpreter} -c '
    import json, sys, jsonschema
    schema = json.load(open(sys.argv[1]))
    jsonschema.Draft202012Validator(schema).validate(json.load(open(sys.argv[2])))
    ' ${cli}/share/dotsteward/schema/context.schema.json context.json
    test "$(jq -r .framework.version context.json)" = "$(cat VERSION)"
    test "$(jq -c '[.components[].name] | sort' context.json)" = "$(jq -c 'sort' ${cli}/share/dotsteward/catalog.json)"
    test "$(jq -r .identity.runtime_matches_check context.json)" = false
    status=0
    env -i HOME="$home" USER=alice DOTSTEWARD_INSTANCE="$instance" \
      ${cli}/bin/dotsteward doctor --json --redact >doctor.json || status=$?
    # No Nix in the sandbox: the nix check fails, so doctor exits 1.
    test "$status" = 1
    test "$(jq -r '.checks[] | select(.id == "nix") | .status' doctor.json)" = fail
    test "$(jq -r .context.identity.runtime_user doctor.json)" = "<redacted>"
  '';
}
