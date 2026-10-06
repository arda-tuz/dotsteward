"""``npm``: the ``latest`` dist-tag of an npm package.

Fields (one of package and package_at):

    package     the package name (a lock template, "{key}" with for_each)
    package_at  lock path of the package name
    registry    registry base URL (default https://registry.npmjs.org)

Query: ``GET <registry>/<package>/latest``. Row details: ``integrity``,
``git_head``, ``node_engine``.

Examples::

    { "id": "agent_tools.example", "adapter": "npm",
      "at": "agent_tools.example", "package_at": "agent_tools.example.package" }
    { "id": "npm.{key}", "adapter": "npm", "for_each": "skills:npm_tools",
      "package": "{key}", "current": "{value}" }
"""

from __future__ import annotations

import urllib.parse
from typing import Any, ClassVar

from ...lockfile import Scope, parse_path, parse_template, scalar_text
from ..model import VERSION_TEXT, Row, classify, item
from ..upstream import Upstream, UpstreamError
from . import Adapter, FieldSpec, PlanContext, Request, url

DEFAULT_REGISTRY = "https://registry.npmjs.org"


class Npm(Adapter):
    name = "npm"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "package": FieldSpec(parse_template),
        "package_at": FieldSpec(parse_path),
        "registry": FieldSpec(url, default=DEFAULT_REGISTRY),
    }

    def validate(self) -> list[str]:
        return self.one_of("package", "package_at")

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        if self.values["package"] is not None:
            package = ctx.locks.render(self.values["package"], scope)
        else:
            package = scalar_text(self.lock_value(ctx.locks, self.values["package_at"], scope))
        request.values["package"] = package

    def default_source(self, request: Request) -> str:
        package = request.values["package"]
        registry = self.values["registry"]
        if registry == DEFAULT_REGISTRY:
            return f"https://www.npmjs.com/package/{package}"
        return f"{registry}/{package}"

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        package = request.values["package"]
        encoded = urllib.parse.quote(package, safe="@")
        data = upstream.http_json(f"{self.values['registry']}/{encoded}/latest")
        version = data.get("version") if isinstance(data, dict) else None
        if not isinstance(version, str) or not VERSION_TEXT.fullmatch(version):
            raise UpstreamError(f"the registry answered no version for {package}: {version!r}")
        dist = data.get("dist") if isinstance(data.get("dist"), dict) else {}
        engines = data.get("engines") if isinstance(data.get("engines"), dict) else {}
        return [
            item(
                request.id,
                self.name,
                request.current,
                version,
                classify(request.current, version, request.held),
                self.source_of(request),
                integrity=dist.get("integrity"),
                git_head=data.get("gitHead"),
                node_engine=engines.get("node"),
                note=request.note,
            )
        ]
