"""``local-apt``: the installation candidate of a package in this machine's
APT configuration (the distribution decides the version; the pin is a
floor). Listed only with --all unless ``optional`` is false.

Fields:

    package   package name (a lock template, required; "{key}" with
              for_each)

Query: ``apt-cache policy <package>``. Status ``follows`` with the
candidate as latest, ``error`` when there is no candidate.

Example::

    { "id": "ubuntu_packages.{key}", "adapter": "local-apt",
      "for_each": "ubuntu_packages", "only_with": "minimum_version",
      "package": "{key}" }
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...lockfile import Scope, parse_template
from ..model import Row, item
from ..upstream import Upstream
from . import Adapter, FieldSpec, PlanContext, Request


class LocalApt(Adapter):
    name = "local-apt"
    OPTIONAL = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "package": FieldSpec(parse_template, required=True),
    }

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        request.values["package"] = ctx.locks.render(self.values["package"], scope)

    def default_source(self, request: Request) -> str:
        return "apt-cache policy"

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        package = request.values["package"]
        output = upstream.run_text(["apt-cache", "policy", package])
        candidate = next(
            (text.split(":", 1)[1].strip() for text in output.splitlines() if text.strip().startswith("Candidate:")),
            None,
        )
        if candidate and candidate != "(none)":
            return [item(request.id, self.name, request.current, candidate, "follows", self.source_of(request))]
        return [
            item(
                request.id,
                self.name,
                request.current,
                None,
                "error",
                self.source_of(request),
                error=f"apt has no installation candidate for {package}",
            )
        ]
