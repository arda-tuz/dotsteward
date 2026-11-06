# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The one TOML reader of the package, dotsteward_cli.tomlfile: a parsed
# document, or one TomlError for text that is not TOML (bad syntax, or bytes
# that are not UTF-8), and the OSError of an unreadable file. tomllib appears
# nowhere else; tomlkit only in the three modules that edit TOML and keep its
# comments. The messages of the configuration reader stay as they were
# (tests/cli/config/test-reader.sh pins them).
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

work=$DS_TEST_ROOT/toml
mkdir -p "$work"
printf 'name = "example"\n[table]\nvalue = 1\nwhen = 2026-01-01\n' >"$work/good.toml"
printf 'name = = 1\n' >"$work/bad.toml"
printf 'name = "\xff"\n' >"$work/binary.toml"

core_python - "$work" <<'PY' || ds_fail "dotsteward_cli.tomlfile"
import datetime
import sys
from pathlib import Path

from dotsteward_cli import tomlfile

work = Path(sys.argv[1])

document = tomlfile.load(work / "good.toml")
assert document == {"name": "example", "table": {"value": 1, "when": datetime.date(2026, 1, 1)}}, document
assert tomlfile.load(str(work / "good.toml")) == document
assert tomlfile.loads('a = "b"\n') == {"a": "b"}

for name, expected in (("bad.toml", "Invalid value"), ("binary.toml", "not valid UTF-8 (invalid start byte at byte ")):
    try:
        tomlfile.load(work / name)
    except tomlfile.TomlError as error:
        assert expected in str(error), error
    else:
        raise AssertionError(f"{name} was accepted")
try:
    tomlfile.loads("a = = 1\n")
except tomlfile.TomlError as error:
    assert "Invalid value" in str(error), error
else:
    raise AssertionError("bad text was accepted")
for missing in (work / "missing.toml", work):
    try:
        tomlfile.load(missing)
    except OSError as error:
        assert error.strerror, error
    else:
        raise AssertionError(f"{missing} was read")
PY

# One reader: tomllib in this module, tomlkit only in the three editors.
readers=$(grep -rlE '^\s*(import|from) tomllib' "$DS_REPO_ROOT/cli/python" "$DS_REPO_ROOT/engines" --include='*.py' || true)
assert_eq "$DS_REPO_ROOT/cli/python/dotsteward_cli/tomlfile.py" "$readers" "the modules that import tomllib"
editors=$(grep -rlE '^\s*(import|from) tomlkit' "$DS_REPO_ROOT/cli/python" "$DS_REPO_ROOT/engines" --include='*.py' | LC_ALL=C sort)
assert_eq "$DS_REPO_ROOT/cli/python/dotsteward_cli/host.py
$DS_REPO_ROOT/cli/python/dotsteward_cli/init.py
$DS_REPO_ROOT/engines/local-maintained-files/local_maintained_files.py" "$editors" "the modules that import tomlkit"
