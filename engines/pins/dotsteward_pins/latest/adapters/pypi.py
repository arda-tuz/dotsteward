"""``pypi``: the newest final release of a package on a Python package
index (the JSON API of PyPI).

Fields (one of package and package_at):

    package     the package name (a lock template, "{key}" with for_each)
    package_at  lock path of the package name
    index       JSON API base URL (default https://pypi.org/pypi)
    integrity   base URL of the integrity API of the index (PEP 740 provenance;
                default: the index with its last segment "pypi" as "integrity")
    repo        owner/name of the GitHub repository that publishes the package
                (a lock template): the first signer of its attestations must be
                a workflow of it (``pins apply``, docs/pins-engine.md); without
                it, the project URLs of the pinned version name it

Query: ``GET <index>/<package>/json``. The newest release whose version is
a final release (digits and dots only: no pre-release, development or
post-release suffix) and that has at least one file that is not yanked.
Row details: ``requires_python`` of the newest file of that release that
declares one. A package the index does not know (HTTP 404), a body without
releases, or no final release with files, is an error row.

Examples::

    { "id": "pypi.example", "adapter": "pypi", "package": "example" }
    { "id": "pypi.{key}", "adapter": "pypi", "for_each": "pypi",
      "package_at": ".distribution" }
"""

from __future__ import annotations

import urllib.error
import urllib.parse
from collections.abc import Callable
from typing import Any, ClassVar

from dotsteward_cli import versions

from ...lockfile import Scope, parse_path, parse_template, scalar_text
from ..model import STABLE_TAG, Row, classify, item
from ..upstream import Upstream, UpstreamError
from . import Adapter, FieldSpec, PlanContext, Request, repository, url

DEFAULT_INDEX = "https://pypi.org/pypi"


def integrity_of(index: str) -> str | None:
    """The integrity API of an index whose JSON API ends in /pypi (as PyPI's does), else None."""
    head, separator, last = index.rstrip("/").rpartition("/")
    return f"{head}/integrity" if separator and last == "pypi" else None


def _available(files: Any) -> list[dict[str, Any]]:
    if not isinstance(files, list):
        return []
    return [entry for entry in files if isinstance(entry, dict) and entry.get("yanked") is not True]


class Pypi(Adapter):
    name = "pypi"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "package": FieldSpec(parse_template),
        "package_at": FieldSpec(parse_path),
        "index": FieldSpec(url, default=DEFAULT_INDEX),
        "integrity": FieldSpec(url),
        "repo": FieldSpec(repository),
    }

    def validate(self) -> list[str]:
        return self.one_of("package", "package_at")

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        if self.values["package"] is not None:
            package = ctx.locks.render(self.values["package"], scope)
        else:
            package = scalar_text(self.lock_value(ctx.locks, self.values["package_at"], scope))
        request.values["package"] = package
        if self.values["repo"] is not None:
            request.values["repo"] = ctx.locks.render(self.values["repo"], scope)

    def default_source(self, request: Request) -> str:
        package = request.values["package"]
        index = self.values["index"]
        if index == DEFAULT_INDEX:
            return f"https://pypi.org/project/{package}/"
        return f"{index}/{package}"

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        return self._newest(request, upstream, lambda version: True)

    def fetch_within(self, request: Request, upstream: Upstream, accept: Callable[[str], bool]) -> list[Row] | None:
        """The newest final release with files that ACCEPT takes."""
        return self._newest(request, upstream, accept, inside=True)

    def _newest(
        self, request: Request, upstream: Upstream, accept: Callable[[str], bool], *, inside: bool = False
    ) -> list[Row]:
        package = request.values["package"]
        encoded = urllib.parse.quote(package, safe="")
        address = f"{self.values['index']}/{encoded}/json"
        try:
            data = upstream.http_json(address)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise UpstreamError(f"{package} is not on the index ({address})") from error
            raise
        releases = data.get("releases") if isinstance(data, dict) else None
        if not isinstance(releases, dict):
            raise UpstreamError(f"the index answered no releases for {package}")
        candidates = {
            version: _available(files)
            for version, files in releases.items()
            if isinstance(version, str) and STABLE_TAG.fullmatch(version) and not version.startswith("v")
        }
        version = versions.newest(version for version, files in candidates.items() if files and accept(version))
        if version is None and inside:
            return [item(request.id, self.name, request.current, request.current, "current", self.source_of(request))]
        if version is None:
            raise UpstreamError(f"{package} has no final release with files")
        requires = [entry["requires_python"] for entry in candidates[version] if entry.get("requires_python")]
        return [
            item(
                request.id,
                self.name,
                request.current,
                version,
                classify(request.current, version, request.held),
                self.source_of(request),
                requires_python=requires[-1] if requires else None,
                note=request.note,
            )
        ]
