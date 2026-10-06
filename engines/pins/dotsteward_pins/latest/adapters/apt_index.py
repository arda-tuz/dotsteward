"""``apt-index``: the newest version of a package in an APT repository
index.

Fields:

    base            repository base URL (required)
    package         package name (a lock template, required)
    arch            architecture (default ``[pins] apt_arch``)
    dist            distribution (default "stable")
    apt_component   repository component (default "main"; the field
                    "component" names the declaring dotsteward component)

Query: ``GET <base>/dists/<dist>/<apt_component>/binary-<arch>/Packages``;
the highest version among the package's stanzas, pre-releases (a "~" in
the version) excluded. Row details: ``url`` (base + Filename), ``size``,
``sha256``. A package missing from the index is an error row.

Example::

    { "id": "desktop_packages.example", "adapter": "apt-index",
      "at": "desktop_packages.example", "base": "https://example.org/apt",
      "package": "example", "dist": "stable" }
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...lockfile import Scope, parse_template
from ...rules import string
from ..model import Row, classify, item, version_key
from ..upstream import Upstream, UpstreamError
from . import Adapter, FieldSpec, PlanContext, Request, url


def stanzas(index: str) -> list[dict[str, str]]:
    """The control stanzas of a Packages index (continuation lines are
    skipped)."""
    result = []
    for stanza in index.replace("\r\n", "\n").split("\n\n"):
        fields = {}
        for text in stanza.splitlines():
            if text.startswith((" ", "\t")) or ": " not in text:
                continue
            name, value = text.split(": ", 1)
            fields[name] = value.strip()
        if fields:
            result.append(fields)
    return result


class AptIndex(Adapter):
    name = "apt-index"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "base": FieldSpec(url, required=True),
        "package": FieldSpec(parse_template, required=True),
        "arch": FieldSpec(string),
        "dist": FieldSpec(string, default="stable"),
        "apt_component": FieldSpec(string, default="main"),
    }

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        request.values["package"] = ctx.locks.render(self.values["package"], scope)
        request.values["arch"] = self.values["arch"] or ctx.instance.config["pins"]["apt_arch"]

    def default_source(self, request: Request) -> str:
        return self.values["base"]

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        base = self.values["base"]
        package = request.values["package"]
        index_url = (
            f"{base}/dists/{self.values['dist']}/{self.values['apt_component']}"
            f"/binary-{request.values['arch']}/Packages"
        )
        entries = [
            fields
            for fields in stanzas(upstream.http_text(index_url))
            if fields.get("Package") == package and "~" not in fields.get("Version", "~")
        ]
        if not entries:
            raise UpstreamError(f"{package} is not in the index {index_url}")
        best = max(entries, key=lambda fields: version_key(fields["Version"]))
        try:
            filename, size, sha256 = best["Filename"], int(best["Size"]), best.get("SHA256")
        except (KeyError, ValueError) as error:
            raise UpstreamError(f"the index stanza of {package} {best['Version']} lacks {error}") from error
        version = best["Version"]
        return [
            item(
                request.id,
                self.name,
                request.current,
                version,
                classify(request.current, version, request.held),
                self.source_of(request),
                url=f"{base}/{filename.lstrip('/')}",
                size=size,
                sha256=sha256,
                note=request.note,
            )
        ]
