"""``text-guard``: an instance file must contain a text built from lock
values (for example a Nix assertion that keeps a package at its pinned
version).

Fields:

    file        instance-relative file (required)
    template    text template of the required text (required)
    regenerate  how ``pins apply`` writes the file again when a pin it guards
                moves: ``{ "package": <nixpkgs attribute on PATH>, "command":
                [argv] }``, the source on standard input and the file on
                standard output. Without it ``pins apply`` has no writer for
                the file, and the row waits for a person.
    for_each, only_with, formats, name   (see rules/__init__.py)

Example::

    { "kind": "text-guard", "file": "home.nix",
      "for_each": "example_policy.exact_versions",
      "template": "pkgs.{key}.version == \\"{value}\\"" }

Check: ``<file>: missing <text!r>`` when the text is absent, ``<file>: no
such file`` when the file is. Check-only.
"""

from __future__ import annotations

from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import DeclarationError, Scope, parse_template
from . import Context, FieldSpec, Rule, relative_file


def _regenerate(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"package", "command"}:
        raise DeclarationError(f"expected an object of package and command, found {value!r}")
    package, command = value["package"], value["command"]
    if not isinstance(package, str) or not package:
        raise DeclarationError(f"expected a nixpkgs attribute as package, found {package!r}")
    if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
        raise DeclarationError(f"expected a non-empty list of arguments as command, found {command!r}")
    return {"package": package, "command": list(command)}


class TextGuard(Rule):
    kind = "text-guard"
    FOR_EACH = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "file": FieldSpec(relative_file, required=True),
        "template": FieldSpec(parse_template, required=True),
        "regenerate": FieldSpec(_regenerate),
    }

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        name = self.values["file"]
        path = ctx.instance.path(name)
        if not path.is_file():
            c.ok(name, False, "no such file")
            return
        text = ctx.locks.render(self.values["template"], scope)
        c.ok(name, text in path.read_text(encoding="utf-8"), f"missing {text!r}")
