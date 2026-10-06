"""``manual``: a pin without an automatic upstream source; the row reminds
the maintainer to look. No query.

Fields:

    latest_at   lock path of a recorded newest version (optional)
    source_at   lock path of the source text (optional; or ``source``)

Status ``held`` when the pin declares a holdback, else ``manual``; the note
is the holdback reason, the declared note, or a reminder to review the
official source.

Example::

    { "id": "nix_packages.example", "adapter": "manual",
      "latest_at": ".latest_stable_version", "source_at": ".official_repository" }
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...lockfile import Scope, parse_path, scalar_text
from ..model import Row, item
from . import Adapter, FieldSpec, PlanContext, Request

DEFAULT_NOTE = "review the official source manually"


class Manual(Adapter):
    name = "manual"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "latest_at": FieldSpec(parse_path),
        "source_at": FieldSpec(parse_path),
    }

    def validate(self) -> list[str]:
        return self.exclusive("source", "source_at")

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        locks = ctx.locks
        latest = self.values["latest_at"]
        source = self.values["source_at"]
        request.values["latest"] = scalar_text(self.lock_value(locks, latest, scope)) if latest is not None else None
        request.values["source"] = scalar_text(self.lock_value(locks, source, scope)) if source is not None else None

    def default_source(self, request: Request) -> str:
        return request.values.get("source") or ""

    def immediate(self, request: Request) -> Row | None:
        status = "held" if request.held else "manual"
        return item(
            request.id,
            self.name,
            request.current,
            request.values["latest"],
            status,
            self.source_of(request),
            note=request.note or DEFAULT_NOTE,
        )
