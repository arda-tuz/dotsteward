# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The one Python package of the framework: pyproject.toml declares one
# distribution with every module of the three source roots, the runtime
# dependencies of the CLI package and the single ruff and mypy configuration.
# The modules stay where they are, because the paths are a contract: the
# commands, the Nix checks and the tests of instances import from them, so
# the entry points and module paths below keep working.

pyproject=$DS_REPO_ROOT/pyproject.toml
[[ -f $pyproject ]] || ds_fail "missing pyproject.toml"

# --- the declaration ---------------------------------------------------------

python3 -I - "$DS_REPO_ROOT" <<'PY' || ds_fail "pyproject.toml does not describe the package"
import pathlib
import re
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
document = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))
project = document["project"]
setuptools = document["tool"]["setuptools"]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


check(project["name"] == "dotsteward", "the distribution is not named dotsteward")
check(project["requires-python"] == ">=3.11", "requires-python is not >=3.11 (the CLI runs python3 -P and tomllib)")
check("version" in project["dynamic"], "the version is not dynamic")
check(setuptools["dynamic"]["version"] == {"file": "VERSION"}, "the version does not come from VERSION")

# Every package and module of the three source roots is declared, nothing else.
directories = setuptools["package-dir"]
expected_dirs = {
    "": "engines/local-maintained-files",
    "dotsteward_cli": "cli/python/dotsteward_cli",
    "dotsteward_pins": "engines/pins/dotsteward_pins",
}
check(directories == expected_dirs, f"package-dir is {directories}")
found_packages = set()
for name in ("dotsteward_cli", "dotsteward_pins"):
    base = root / directories[name]
    found_packages.update(
        ".".join((name, *path.parent.relative_to(base).parts)) for path in base.rglob("__init__.py")
    )
check(set(setuptools["packages"]) == found_packages, f"packages differ from the tree: {sorted(found_packages)}")
modules = {path.stem for path in (root / directories[""]).glob("*.py")}
check(set(setuptools["py-modules"]) == modules, f"py-modules differ from the tree: {sorted(modules)}")

# The dependencies are what the CLI package puts into its python.
package = (root / "nix/packages/dotsteward.nix").read_text(encoding="utf-8")
match = re.search(r"python3\.withPackages \(ps: \[ ([^]]*) \]\)", package)
check(match is not None, "nix/packages/dotsteward.nix has no python3.withPackages line")
if match:
    nix_names = sorted(name.removeprefix("ps.") for name in match.group(1).split())
    check(sorted(project["dependencies"]) == nix_names, f"the CLI package's python has {nix_names}")

# One lint and type configuration, every package and module under it.
ruff = document["tool"]["ruff"]
check(ruff["line-length"] == 120, "the ruff line length is not 120")
check(ruff["target-version"] == "py311", "the ruff target is not requires-python")
check(ruff["lint"]["select"] == ["E", "F", "W", "B", "UP", "SIM", "RUF"], "the ruff rule set changed")
mypy = document["tool"]["mypy"]
check(mypy["strict"] is True, "mypy is not strict")
check(mypy["python_version"] == "3.11", "mypy does not check for requires-python")
check(mypy["mypy_path"].split(":") == ["cli/python", "engines/pins", directories[""]], "mypy_path lacks a source root")
check(set(mypy["packages"]) == {"dotsteward_cli", "dotsteward_pins"}, "mypy skips a package")
check(set(mypy["modules"]) == modules, "mypy skips a module")

# Lint rules are configured here only.
checks = root / "nix/checks"
for path in sorted(checks.glob("*.nix")) if checks.is_dir() else []:
    text = path.read_text(encoding="utf-8")
    check("--select" not in text and "--line-length" not in text, f"{path.name} configures ruff itself")

for failure in failures:
    print(f"pyproject.toml: {failure}", file=sys.stderr)
sys.exit(1 if failures else 0)
PY

# --- entry points and module paths ----------------------------------------------

# python_at ROOTS ARG...: python3 as the commands run it, with the colon
# separated source roots ROOTS below the framework on its module path.
python_at() {
  local roots=$1 entry import_path=''
  shift
  IFS=: read -r -a entries <<<"$roots"
  for entry in "${entries[@]}"; do
    import_path+=${import_path:+:}$DS_REPO_ROOT/$entry
  done
  PYTHONPATH=$import_path PYTHONDONTWRITEBYTECODE=1 python3 -s -P "$@"
}

# The command modules, each with the module path its command gives it.
assert_exit 0 python_at cli/python -m dotsteward_cli.config --help
assert_exit 0 python_at cli/python -m dotsteward_cli.context --help
assert_exit 0 python_at cli/python -m dotsteward_cli.doctor --help
assert_exit 0 python_at cli/python -m dotsteward_cli.init --help
assert_exit 0 python_at engines/pins:cli/python -m dotsteward_pins --help
assert_exit 0 python_at engines/local-maintained-files:cli/python -m local_maintained_files --help
assert_eq 'dotsteward_cli' "$(python_at cli/python -c 'import dotsteward_cli; print(dotsteward_cli.__name__)')"
assert_exit 0 python_at engines/local-maintained-files -c 'import jsonc, lmf_validate'

# The names that the Python tests of instances import, from the paths they
# put on sys.path themselves.
python3 -s -P - "$DS_REPO_ROOT" <<'PY' || ds_fail "a module path that instances import is gone"
import sys

framework = sys.argv[1]
sys.path[:0] = [f"{framework}/engines/pins", f"{framework}/cli/python"]

from dotsteward_pins.checker import Checker
from dotsteward_pins.instance import Declaration, EngineError, Instance
from dotsteward_pins.latest import core
from dotsteward_pins.latest.adapters import PlanContext, declared
from dotsteward_pins.lockfile import SKILLS, VERSIONS, Locks
from dotsteward_pins.rules import KINDS, Context, make

for name in (Checker, Declaration, EngineError, Instance, core, PlanContext, declared, SKILLS, VERSIONS, Locks):
    assert name is not None
assert callable(make) and KINDS and Context
PY
