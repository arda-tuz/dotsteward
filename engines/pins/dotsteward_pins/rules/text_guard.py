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
such file`` when the file is. When the text is a requirement ``<name>==<version>`` of a
pypi pin (``pypi.<name>``) whose signer in ``trust.signers`` is sigstore, the pin records
the files its attestations vouch for (``signature.files``, written by ``pins apply``) and
every ``--hash`` of that requirement in the file is one of them: a signed source never
installs a file nobody attested. Check-only.
"""

from __future__ import annotations

from typing import Any, ClassVar

import re

from .. import requirements
from ..checker import Checker
from ..lockfile import VERSIONS, DeclarationError, Placeholder, Scope, parse_template
from . import Context, FieldSpec, Rule, relative_file

_REQUIREMENT = re.compile(r"([A-Za-z0-9][A-Za-z0-9._-]*)==(\S+)")


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
        content = path.read_text(encoding="utf-8")
        c.ok(name, text in content, f"missing {text!r}")
        requirement = _REQUIREMENT.fullmatch(text)
        if requirement is not None:
            for pin in self._pypi_pins():
                _check_signed(ctx, c, pin, requirement[1], requirement[2], content)

    def _pypi_pins(self) -> list[str]:
        """The pypi pins (``pypi.<name>``) the template names."""
        pins = []
        for part in self.values["template"].parts:
            path = part.path if isinstance(part, Placeholder) else None
            if path is None or path.relative or path.file != VERSIONS or len(path.steps) < 2:
                continue
            if path.steps[0].key == "pypi" and isinstance(path.steps[1].key, str):
                pins.append(f"pypi.{path.steps[1].key}")
        return list(dict.fromkeys(pins))


def _check_signed(ctx: Context, c: Checker, pin: str, name: str, version: str, content: str) -> None:
    versions = ctx.locks.documents.get(VERSIONS)
    trust = versions.get("trust") if isinstance(versions, dict) else None
    signers = trust.get("signers") if isinstance(trust, dict) else None
    signer = signers.get(pin) if isinstance(signers, dict) else None
    if not isinstance(signer, dict) or signer.get("kind") != "sigstore":
        return
    section = versions.get("pypi") if isinstance(versions, dict) else None
    entry = section.get(pin.split(".", 1)[1]) if isinstance(section, dict) else None
    signature = entry.get("signature") if isinstance(entry, dict) else None
    files = signature.get("files") if isinstance(signature, dict) else None
    if not isinstance(files, dict) or not files:
        c.ok(f"trust.signers.{pin}", False, f"a signed source, and {pin} records no signature")
        return
    vouched = {str(digest).lower() for digest in files.values()}
    extra = [digest for digest in requirements.hashes(name, version, content) if digest not in vouched]
    c.ok(
        pin,
        not extra,
        f"the requirements allow a file its attestations do not vouch for: sha256:{extra[0] if extra else ''}",
    )
