"""``follows``: a pin whose version is derived from another pin or input,
so it has no upstream of its own. No query; listed only with --all unless
``optional`` is false.

Fields:

    follows   what the version follows (required); the row kind is
              ``follows-<follows>`` and the source ``<follows>``

Example::

    { "id": "nix_packages.{key}", "adapter": "follows",
      "for_each": "example_tool.exact_versions", "current": "{value}",
      "follows": "example-tool", "note": "pinned by example-tool" }
"""

from __future__ import annotations

from typing import ClassVar

from ...rules import string
from ..model import Row, item
from . import Adapter, FieldSpec, Request


class Follows(Adapter):
    name = "follows"
    OPTIONAL = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "follows": FieldSpec(string, required=True),
    }

    def default_source(self, request: Request) -> str:
        return self.values["follows"]

    def immediate(self, request: Request) -> Row | None:
        return item(
            request.id,
            f"follows-{self.values['follows']}",
            request.current,
            None,
            "follows",
            self.source_of(request),
            note=request.note,
        )
