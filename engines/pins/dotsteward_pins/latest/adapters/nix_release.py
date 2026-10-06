"""``nix-release``: the newest stable Nix release and its installer.

Fields:

    repo          GitHub repository whose stable tags are the releases
                  (required)
    url_template  release template ({version}) of the installer URL;
                  default: the pin's url_field value with the current
                  version replaced by {version}
    url_field     pin field holding the installer URL (default
                  "installer_url")
    sha256_suffix suffix of the published checksum file next to the
                  installer (default ".sha256")

Query: ``git ls-remote --tags`` of the repository; the checksum file
(GET) and the installer size (HEAD). Row details: ``url``, ``size``,
``sha256``. The default source is the URL template up to the directory
that holds {version}. The core row ``nix.installer`` is built from the
lock's ``nix`` section (core.py).
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...checker import HEX64
from ...lockfile import Scope
from ...rules import string
from .. import templates
from ..model import Row, classify, item
from ..upstream import Upstream, UpstreamError, github_url, tag_version
from . import Adapter, FieldSpec, PlanContext, PlanError, Request, repository


class NixRelease(Adapter):
    name = "nix-release"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "repo": FieldSpec(repository, required=True),
        "url_template": FieldSpec(templates.parser("version")),
        "url_field": FieldSpec(string, default="installer_url"),
        "sha256_suffix": FieldSpec(string, default=".sha256"),
    }

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        request.values["repo"] = ctx.locks.render(self.values["repo"], scope)
        template = self.values["url_template"]
        if template is None:
            field_name = self.values["url_field"]
            installer = pin.get(field_name) if isinstance(pin, dict) else None
            current = request.current or ""
            if not isinstance(installer, str) or not current or current not in installer:
                raise PlanError(f"cannot derive the installer URL template from {field_name} {installer!r}")
            template = templates.parse(installer.replace(current, "{version}"), ("version",))
        request.values["template"] = template

    def default_source(self, request: Request) -> str:
        text = request.values["template"].source
        return text[: text.rfind("/", 0, text.index("{version}")) + 1] if "{version}" in text else text

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        repo = request.values["repo"]
        tag = upstream.newest_tag(github_url(repo))
        if tag is None:
            raise UpstreamError(f"{repo} has no stable tag")
        version = tag_version(tag)
        installer = request.values["template"].render(version=version)
        sha256 = upstream.http_text(installer + self.values["sha256_suffix"]).strip()
        if not HEX64.fullmatch(sha256):
            raise UpstreamError(f"{installer}{self.values['sha256_suffix']} is not a hex SHA-256: {sha256[:80]!r}")
        size = upstream.http_head(installer).size
        return [
            item(
                request.id,
                self.name,
                request.current,
                version,
                classify(request.current, version, request.held),
                self.source_of(request),
                url=installer,
                size=size,
                sha256=sha256,
                note=request.note,
            )
        ]
