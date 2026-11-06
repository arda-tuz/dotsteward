"""``framework`` (built in): the instance's dotsteward release against the
newest release of its upstream.

The row ``framework`` reads the ``dotsteward`` input of the instance's
``flake.lock``: ``original`` is a ``github`` owner/repo (newest release
from ``gh``, with the stable-tag fallback) or a ``git`` URL (newest stable
tag from ``git ls-remote``). Pinned to a release tag (``original.ref``,
the current tag): status ``review`` when a newer release exists, else
``current``. Pinned to a commit (``original.rev``, as ``dotsteward
contribute upgrade --main`` writes it, the main commit a contribution's
check and trial passed for; current is its 12-digit form): ``current``
while the commit contains the newest release (the release's commit is the
commit or one of its ancestors, from a temporary fetch of the commits
only), ``review`` once a newer release exists. ``manual`` for an input
pinned to neither (a branch) or a local path; ``error`` for a missing
input or lock file, unknown input types and a commit the upstream does not
have. Details: ``tag`` (the newest release tag) and ``upstream``; for a
commit also ``rev`` (the full commit) and ``contains``.
"""

from __future__ import annotations

import tempfile
from typing import Any

from ...checker import HEX40
from ...instance import Instance
from ...lockfile import load_json
from ..model import Row, error_item, item, version_key
from ..upstream import Upstream, UpstreamError, github_url, is_stable_tag
from . import Adapter, Planned, Request

INPUT = "dotsteward"
ROW_ID = "framework"


class Framework(Adapter):
    name = "framework"
    VERSIONED = False
    BUILT_IN = True

    def default_source(self, request: Request) -> str:
        return str(request.values["source"])

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        values = request.values
        if values["type"] == "github":
            tag, _ = upstream.latest_release(values["repo"])
            url = github_url(values["repo"])
        else:
            tag = upstream.newest_tag(values["url"])
            url = values["url"]
        if tag is None:
            raise UpstreamError(f"{values['upstream']} has no stable release or tag")
        details: dict[str, Any] = {"tag": tag, "upstream": values["upstream"]}
        rev = values.get("rev")
        if rev is None:
            status = "review" if version_key(tag) > version_key(request.current) else "current"
        else:
            contains = commit_contains(upstream, url, tag, rev)
            status = "current" if contains else "review"
            details.update(rev=rev, contains=contains)
        return [item(ROW_ID, self.name, request.current, tag, status, self.source_of(request), **details)]


def commit_contains(upstream: Upstream, url: str, tag: str, rev: str) -> bool:
    """Whether commit REV of the git repository URL contains the release tag
    TAG (TAG's commit is REV or one of its ancestors), from a temporary bare
    repository that fetches the commits of both and no files."""
    with tempfile.TemporaryDirectory(prefix="dotsteward-pins-") as work:
        try:
            upstream.run_text(["git", "init", "--quiet", "--bare", work])
            refspec = f"+refs/tags/{tag}:refs/tags/{tag}"
            fetch = ["git", "-C", work, "fetch", "--quiet", "--no-tags", "--filter=tree:0"]
            upstream.run_text([*fetch, url, refspec, rev])
            # The commits of TAG that REV lacks: none when REV contains it.
            released = f"refs/tags/{tag}^{{commit}}"
            missing = upstream.run_text(["git", "-C", work, "rev-list", "-n", "1", released, f"^{rev}"])
        except RuntimeError as failure:
            raise UpstreamError(f"cannot tell whether {rev[:12]} contains {tag}: {failure}") from failure
    return not missing.strip()


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
    rev = original.get("rev")
    if not is_stable_tag(current):
        if isinstance(rev, str) and HEX40.fullmatch(rev):
            values["rev"] = rev
            return Planned(ROW_ID, "core", False, Request(ROW_ID, adapter, current=rev[:12], values=values), None)
        note = f"the {INPUT} input is not pinned to a release tag or a commit"
        source, upstream = values["source"], values["upstream"]
        return row(item(ROW_ID, Framework.name, current, None, "manual", source, note=note, upstream=upstream))
    request = Request(ROW_ID, adapter, current=current, values=values)
    return Planned(ROW_ID, "core", False, request, None)
