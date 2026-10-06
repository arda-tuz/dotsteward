# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness
# jsonc.strip, the JSONC reader of the settings engine, on its own: comments
# (`//`, `/* */`) and trailing commas outside strings are removed and
# reported, everything inside strings is kept (escaped quotes and
# backslashes included), the text keeps its length and line breaks (so
# json.loads reports positions of the original file), and an unterminated
# block comment is a ValueError.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

fixtures=$DS_REPO_ROOT/tests/engines/settings/jsonc/fixtures/commented

PYTHONPATH=$DS_REPO_ROOT/engines/local-maintained-files PYTHONDONTWRITEBYTECODE=1 \
  python3 - "$fixtures" <<'PY' || ds_fail "jsonc.strip does not behave as specified"
import json
import pathlib
import sys

import jsonc

fixtures = pathlib.Path(sys.argv[1])
failures = []


def check(name, text, expected, changed):
    try:
        stripped, was_changed = jsonc.strip(text)
    except Exception as error:
        failures.append(f"{name}: raised {error!r}")
        return
    if was_changed is not changed:
        failures.append(f"{name}: changed is {was_changed!r}, expected {changed!r}")
    if len(stripped) != len(text) or [i for i, c in enumerate(stripped) if c == "\n"] != [
        i for i, c in enumerate(text) if c == "\n"
    ]:
        failures.append(f"{name}: the length or the line breaks moved: {stripped!r}")
    if expected is not None:
        try:
            value = json.loads(stripped)
        except ValueError as error:
            failures.append(f"{name}: not JSON after strip ({error}): {stripped!r}")
            return
        if value != expected or (isinstance(value, dict) and list(value) != list(expected)):
            failures.append(f"{name}: {value!r} != {expected!r}")


typical = {"editor.fontSize": 14, "workbench.colorTheme": "dark"}
check("line comments", (fixtures / "line-comments.json").read_text(), typical, True)
check("block comments", (fixtures / "block-comments.json").read_text(), typical, True)
check(
    "trailing commas",
    (fixtures / "trailing-commas.json").read_text(),
    {
        "editor.fontSize": 14,
        "files.exclude": {"**/.git": True},
        "editor.rulers": [80, 120],
        "workbench.colorTheme": "dark",
    },
    True,
)
check(
    "comment-like strings",
    (fixtures / "comment-like-strings.json").read_text(),
    {
        "workbench.colorTheme": "light",
        "http.proxy": "http://proxy.example.invalid:8080",
        "search.pattern": "/* not a comment */",
        "quoted": 'a"//b',
        "backslash": "c:\\",
        "list": ["x,", "]"],
        "editor.fontSize": 12,
    },
    False,
)
check("empty", "", None, False)
check("plain JSON", '{"a": [1, 2], "b": {"c": null}}\n', {"a": [1, 2], "b": {"c": None}}, False)
check("comment before the closing brace", '{"a": 1 /* x */}', {"a": 1}, True)
check("trailing comma behind a comment", "[1, /* c */\n]", [1], True)
check("trailing comma behind a line comment", "[1, // c\n]", [1], True)
check("comma before a commented value", "[1, // c\n 2]", [1, 2], True)
check("only a comment", "// nothing here\n", None, True)
check("comment at the end without newline", '{"a": 1} // end', {"a": 1}, True)
check("crlf line comment", '{\r\n  "a": 1 // c\r\n}\r\n', {"a": 1}, True)
check("slashes in keys", '{"//": "/*", "*/": "//"}', {"//": "/*", "*/": "//"}, False)
check("escaped backslash before the quote", '{"a": "\\\\", "b": 2,}', {"a": "\\", "b": 2}, True)
check("unicode", '{"name": "caf\u00e9" /* x */}', {"name": "caf\u00e9"}, True)

# A lone slash is not a comment: it stays and json.loads rejects it.
stripped, changed = jsonc.strip('{"a": 1 / 2}')
if stripped != '{"a": 1 / 2}' or changed:
    failures.append(f"lone slash: {stripped!r} {changed!r}")

for text in ('{"a": 1 /* open', "/*", '{"a": "x"} /* never closed\n'):
    try:
        jsonc.strip(text)
    except ValueError as error:
        if "unterminated" not in str(error):
            failures.append(f"unterminated comment {text!r}: message {error}")
    else:
        failures.append(f"unterminated comment {text!r}: no ValueError")

for failure in failures:
    print(failure)
sys.exit(1 if failures else 0)
PY
