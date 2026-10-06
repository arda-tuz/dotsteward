"""``github-release``: the newest stable release of a GitHub repository.

Fields:

    repo        owner/name (a lock template); default: the pin's
                ``reference`` (``github:owner/name/...``)
    tag_prefix  tag family of the releases (for example "rust-v"); without
                it, tags are versions with an optional leading v
    asset       release template ({version}, {tag}) of the asset name to
                report (size, digest, URL); missing assets are reported as
                ``asset_missing``

Query: ``gh api repos/<repo>/releases/latest``; when gh fails or answers a
tag outside the family, the newest stable tag from ``git ls-remote
--tags`` (no asset details then). Row details: ``tag`` and the asset's
``asset``, ``size``, ``sha256``, ``url`` (or ``asset_missing``).

Examples::

    { "id": "nix_packages.example", "adapter": "github-release",
      "repo": "example-org/example" }
    { "id": "agent_tools.example.linux", "adapter": "github-release",
      "at": "agent_tools.example.linux", "repo": "example-org/example",
      "tag_prefix": "cli-v", "asset": "example-{version}-linux-x64.tar.gz" }
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...lockfile import Scope
from .. import templates
from ..model import Row, classify, item
from ..upstream import Upstream, UpstreamError, github_repo, github_url, tag_version
from . import Adapter, FieldSpec, PlanContext, PlanError, Request, repository, text


def repo_of_pin(pin: Any) -> str:
    """owner/name from the pin's ``reference`` (PlanError otherwise)."""
    reference = pin.get("reference") if isinstance(pin, dict) else None
    repo = github_repo(reference) if isinstance(reference, str) and reference.startswith("github:") else None
    if repo is None:
        raise PlanError(f"the pin's reference {reference!r} is not a GitHub reference; declare 'repo'")
    return repo


class GithubRelease(Adapter):
    name = "github-release"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "repo": FieldSpec(repository),
        "tag_prefix": FieldSpec(text, default=""),
        "asset": FieldSpec(templates.parser("version", "tag")),
    }

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        template = self.values["repo"]
        request.values["repo"] = ctx.locks.render(template, scope) if template is not None else repo_of_pin(pin)

    def default_source(self, request: Request) -> str:
        return f"{github_url(request.values['repo'])}/releases"

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        repo = request.values["repo"]
        prefix = self.values["tag_prefix"]
        tag, release = upstream.latest_release(repo, prefix)
        if tag is None:
            raise UpstreamError(f"{repo} has no stable release or tag")
        latest = tag_version(tag, prefix)
        details: dict[str, Any] = {"tag": tag}
        asset = self.values["asset"]
        if release is not None and asset is not None:
            name = asset.render(version=latest, tag=tag)
            assets = release.get("assets") if isinstance(release.get("assets"), list) else []
            match = next((entry for entry in assets if isinstance(entry, dict) and entry.get("name") == name), None)
            if match is not None:
                digest = str(match.get("digest") or "").removeprefix("sha256:") or None
                details.update(asset=name, size=match.get("size"), sha256=digest, url=match.get("browser_download_url"))
            else:
                details["asset_missing"] = name
        status = classify(request.current, latest, request.held)
        return [
            item(
                request.id,
                self.name,
                request.current,
                latest,
                status,
                self.source_of(request),
                **details,
                note=request.note,
            )
        ]
