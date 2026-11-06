# The Python package of the framework (tests/cli/core): its declaration in
# pyproject.toml, the entry points and module paths that bash, Nix and
# instances use, and the shared primitives driven through their entry points.
# Then shellcheck over the tests and the one lint of all Python: ruff and
# ruff format over every Python file of the source set, mypy in strict mode
# over the package (rules and paths: pyproject.toml), and a wheel build that
# proves the declaration holds every module. The lint job of ci.yml builds
# this check on every event.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  # mypy sees the dependencies of the package; the build tools build it.
  tools = pkgs.python3.withPackages (ps: [
    ps.mypy
    ps.tomlkit
    ps.build
    ps.setuptools
  ]);
in
cli.mkTestCheck {
  name = "python-core";
  paths = [ "tests/cli/core" ];
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.ruff
  ];
  postCheck = ''
    shellcheck -x tests/cli/core/*.sh
    ruff check --no-cache --quiet .
    ruff format --no-cache --quiet --check .
    ${tools}/bin/mypy
    ${tools.interpreter} -m build --no-isolation --wheel --outdir "$TMPDIR/dist" . >"$TMPDIR/build.log" 2>&1 || {
      cat "$TMPDIR/build.log" >&2
      exit 1
    }
    declared=$(find cli/python/dotsteward_cli engines/pins/dotsteward_pins engines/local-maintained-files \
      -name '*.py' -printf '%f\n' | LC_ALL=C sort)
    ${tools.interpreter} -m zipfile --list "$TMPDIR"/dist/*.whl >"$TMPDIR/wheel.txt"
    built=$(awk '$1 ~ /\.py$/ { n = split($1, parts, "/"); print parts[n] }' "$TMPDIR/wheel.txt" | LC_ALL=C sort)
    if [[ $declared != "$built" ]]; then
      printf 'the wheel does not hold the modules of the tree:\n%s\n---\n%s\n' "$declared" "$built" >&2
      exit 1
    fi
  '';
}
