# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The Python reader's command line: output streams, exit codes, TOML parse
# errors, dates (refused like Nix fromTOML does) and usage errors.
# shellcheck source=tests/cli/config/helpers.sh
source "$DS_REPO_ROOT/tests/cli/config/helpers.sh"

catalog=$(config_catalog)
minimal=$nix_valid_fixtures/minimal.toml

# A valid file: no messages, the resolved value on stdout only.
assert_exit 0 config_py --file "$minimal" --catalog "$catalog" errors
assert_eq '[]' "$DS_STDOUT"
assert_eq '' "$DS_STDERR"
assert_exit 0 config_py --file "$minimal" --catalog "$catalog" resolve
assert_json - '.identity.username == "alice" and .profiles.check == "main"' <<<"$DS_STDOUT"
assert_eq '' "$DS_STDERR"
[[ $(printf '%s\n' "$DS_STDOUT" | wc -l) == 1 ]] || ds_fail "resolve prints one JSON line: [$DS_STDOUT]"

# An invalid file: every message on stderr with the error prefix, in the
# order of the Nix reader, nothing on stdout, exit 1.
assert_exit 1 config_py --file "$nix_invalid_fixtures/wrong-type.toml" --catalog "$catalog" resolve
assert_eq '' "$DS_STDOUT"
expected=$(sed -n 's/^# expect: /[dotsteward] ERROR: workstation.toml: /p' "$nix_invalid_fixtures/wrong-type.toml")
assert_eq "$expected" "$DS_STDERR" "every message, in order"
# errors lists the same messages and still succeeds.
assert_exit 0 config_py --file "$nix_invalid_fixtures/wrong-type.toml" --catalog "$catalog" errors
assert_eq "$(sed -n 's/^# expect: //p' "$nix_invalid_fixtures/wrong-type.toml" | jq -R . | jq -cs .)" \
  "$(jq -c . <<<"$DS_STDOUT")"

# A TOML syntax error is one message and exit 1, for every command.
printf 'schema_version = = 1\n' >"$DS_TEST_ROOT/broken.toml"
for command in errors resolve; do
  assert_exit 1 config_py --file "$DS_TEST_ROOT/broken.toml" --catalog "$catalog" "$command"
  assert_eq '' "$DS_STDOUT"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: workstation.toml: invalid TOML: "
  assert_not_contains "$DS_STDERR" "Traceback"
done

# Dates and times are refused like Nix fromTOML refuses them, wherever they
# appear (also inside component options).
cp "$minimal" "$DS_TEST_ROOT/dated.toml"
printf '[components.example-app]\noptions = { since = 2026-01-01, at = 10:30:00 }\n' >>"$DS_TEST_ROOT/dated.toml"
assert_exit 1 config_py --file "$DS_TEST_ROOT/dated.toml" --catalog "$catalog" resolve
assert_eq '[dotsteward] ERROR: workstation.toml: invalid TOML: dates and times are not supported (components.example-app.options.at)' \
  "$DS_STDERR"
assert_exit 1 config_py --file "$DS_TEST_ROOT/dated.toml" --catalog "$catalog" errors
assert_contains "$DS_STDERR" "dates and times are not supported"

# Infinite and NaN floats have no JSON form and are refused.
cp "$minimal" "$DS_TEST_ROOT/nan.toml"
printf '[components.example-app]\noptions = { ratio = nan }\n' >>"$DS_TEST_ROOT/nan.toml"
assert_exit 1 config_py --file "$DS_TEST_ROOT/nan.toml" --catalog "$catalog" resolve
assert_eq '[dotsteward] ERROR: workstation.toml: invalid TOML: components.example-app.options.ratio: nan is not a finite number' \
  "$DS_STDERR"

# A missing or unreadable file.
assert_exit 1 config_py --file "$DS_TEST_ROOT/missing.toml" --catalog "$catalog" resolve
assert_eq "[dotsteward] ERROR: cannot read $DS_TEST_ROOT/missing.toml: No such file or directory" "$DS_STDERR"
mkdir "$DS_TEST_ROOT/a-directory"
assert_exit 1 config_py --file "$DS_TEST_ROOT/a-directory" --catalog "$catalog" resolve
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read $DS_TEST_ROOT/a-directory: "

# Invalid UTF-8 is a TOML error, not a crash.
{
  cat "$minimal"
  printf '[components.example-app]\noptions = { name = "\xff" }\n'
} >"$DS_TEST_ROOT/binary.toml"
assert_exit 1 config_py --file "$DS_TEST_ROOT/binary.toml" --catalog "$catalog" resolve
assert_contains "$DS_STDERR" "[dotsteward] ERROR: workstation.toml: invalid TOML: "
assert_not_contains "$DS_STDERR" "Traceback"

# Usage errors exit 1 (the bash convention), never argparse's 2.
assert_exit 1 config_py
assert_contains "$DS_STDERR" "usage:"
assert_exit 1 config_py --file "$minimal" frobnicate
assert_contains "$DS_STDERR" "usage:"
assert_exit 1 config_py --no-such-option resolve
assert_contains "$DS_STDERR" "usage:"
assert_exit 1 config_py --file "$minimal" --instance "$DS_TEST_ROOT" resolve
assert_contains "$DS_STDERR" "--file and --instance are mutually exclusive"
assert_exit 1 config_py --file "$minimal" --catalog "shell,Not A Name" resolve
assert_contains "$DS_STDERR" "invalid catalog component name"
assert_exit 0 config_py --help
assert_contains "$DS_STDOUT" "usage:"
for command in resolve errors export discover; do
  assert_contains "$DS_STDOUT" "$command"
done

# The module is importable without side effects and exposes the reader API
# the other Python engines use.
PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - "$minimal" <<'EOF'
import sys

from dotsteward_cli import config

raw = config.read_toml(sys.argv[1])
assert config.errors(raw, catalog=["shell"]) == [], "no errors"
resolved = config.resolve(raw, catalog=["shell"], instance_name="ws")
assert resolved["instance"]["name"] == "ws", resolved["instance"]
assert resolved["components"]["order"] == ["shell"], resolved["components"]
try:
    config.resolve({"schema_version": 2}, catalog=[])
except config.ConfigError as error:
    assert error.messages[0].startswith("schema_version 2 is not supported"), error.messages
else:
    raise AssertionError("resolve accepted schema_version 2")
EOF
