"""``framework`` (built in): the instance's dotsteward release against the
newest release of its upstream.

The row ``framework`` reads the ``dotsteward`` input of the instance's
``flake.lock``: ``original.ref`` is the current tag; ``original`` is
a ``github`` owner/repo (newest release from ``gh``, with the stable-tag
fallback) or a ``git`` URL (newest stable tag from ``git ls-remote``).
Status ``review`` when a newer release exists, else ``current``; ``manual``
for an input that is not pinned to a release tag or is a local path;
``error`` for a missing input or lock file and unknown input types.
Details: ``tag`` (the newest release tag) and ``upstream``.
"""

from __future__ import annotations

from typing import Any

from ...instance import Instance
from ...lockfile import load_json
from ..model import Row, error_item, item, version_key
from ..upstream import Upstream, UpstreamError, is_stable_tag
from . import Adapter, Planned, Request

INPUT = "dotsteward"
ROW_ID = "framework"


class Framework(Adapter):
    name = "framework"
    VERSIONED = False
    BUILT_IN = True

    def default_source(self, request: Request) -> str:
        return request.values["source"]

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        values = request.values
        if values["type"] == "github":
            tag, _ = upstream.latest_release(values["repo"])
        else:
            tag = upstream.newest_tag(values["url"])
        if tag is None:
            raise UpstreamError(f"{values['upstream']} has no stable release or tag")
        status = "review" if version_key(tag) > version_key(request.current) else "current"
        return [
            item(
                ROW_ID,
                self.name,
                request.current,
                tag,
                status,
                self.source_of(request),
                tag=tag,
                upstream=values["upstream"],
            )
        ]


def plan(instance: Instance) -> Planned:
    """The framework row's request (or its manual or error row)."""
    adapter = Framework("core", {"id": ROW_ID, "adapter": Framework.name})

    def row(value: Row) -> Planned:
        return Planned(ROW_ID, "core", False, None, value)

    def error(message: str) -> Planned:
        return row(error_item(ROW_ID, Framework.name, message))

    try:
        lock = load_json(instance.path("flake.lock"))
    except OSError as failure:
        return error(f"cannot read flake.lock: {failure.strerror or failure}")
    except ValueError as failure:
        return error(f"cannot read flake.lock: invalid JSON ({failure})")
    try:
        nodes = lock["nodes"]
        name = nodes[lock["root"]].get("inputs", {}).get(INPUT)
    except (KeyError, TypeError, AttributeError):
        return error("flake.lock has no root node")
    if name is None:
        return error(f"flake.lock has no {INPUT} input")
    if not isinstance(name, str):
        return error(f"the {INPUT} input of flake.lock follows another input")
    original: Any = nodes.get(name, {}).get("original") if isinstance(nodes.get(name), dict) else None
    if not isinstance(original, dict):
        return error(f"the {INPUT} node of flake.lock has no original reference")

    kind = original.get("type")
    values: dict[str, Any] = {"type": kind}
    if kind == "github" and isinstance(original.get("owner"), str) and isinstance(original.get("repo"), str):
        repo = f"{original['owner']}/{original['repo']}"
        values.update(repo=repo, upstream=f"github:{repo}", source=f"https://github.com/{repo}/releases")
    elif kind == "git" and isinstance(original.get("url"), str):
        values.update(url=original["url"], upstream=original["url"], source=original["url"])
    elif kind == "path":
        path = str(original.get("path", ""))
        note = f"the {INPUT} input is a local path; it has no releases"
        return row(item(ROW_ID, Framework.name, None, None, "manual", path, note=note, upstream=path))
    else:
        return error(f"unsupported {INPUT} input type {kind!r}")

    ref = original.get("ref")
    current = ref.removeprefix("refs/tags/") if isinstance(ref, str) else None
    if not is_stable_tag(current):
        note = f"the {INPUT} input is not pinned to a release tag"
        source, upstream = values["source"], values["upstream"]
        return row(item(ROW_ID, Framework.name, current, None, "manual", source, note=note, upstream=upstream))
    request = Request(ROW_ID, adapter, current=current, values=values)
    return Planned(ROW_ID, "core", False, request, None)
