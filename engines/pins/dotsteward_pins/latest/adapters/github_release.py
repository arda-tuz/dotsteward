"""``github-release``: the newest stable release of a GitHub repository.

Fields:

    repo        owner/name (a lock template); default: the pin's
                ``reference`` (``github:owner/name/...``)
    tag_prefix  tag family of the releases (for example "rust-v"); without
                it, tags are versions with an optional leading v
    asset       release template ({version}, {tag}) of the asset name to
                report (size, digest, URL), or an object of such templates
                per Nix system (x86_64-linux, aarch64-darwin) or platform
                (linux, darwin) for an asset that differs from platform to
                platform; missing assets are reported as ``asset_missing``

Query: ``gh api repos/<repo>/releases/latest``; when gh fails or answers a
tag outside the family, the newest stable tag from ``git ls-remote
--tags`` (no asset details then). Row details: ``tag`` and the asset's
``asset``, ``size``, ``sha256``, ``url`` (or ``asset_missing``); with an
asset object, ``assets.<key>`` holds those fields for each declared key,
all from the same release.

A row id is the same on every system: every system's manifest mirror
carries the same declaration (an asset object rather than an asset that
changes from system to system), so the mirrors unite into one row.

Examples::

    { "id": "nix_packages.example", "adapter": "github-release",
      "repo": "example-org/example" }
    { "id": "agent_tools.example", "adapter": "github-release",
      "at": "agent_tools.example", "repo": "example-org/example",
      "tag_prefix": "cli-v",
      "asset": { "x86_64-linux": "example-{version}-linux-x64.tar.gz",
                 "aarch64-darwin": "example-{version}-darwin-arm64.zip" } }
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...lockfile import DeclarationError, Scope
from .. import templates
from ..model import Row, classify, item
from ..upstream import Upstream, UpstreamError, github_repo, github_url, tag_version
from . import Adapter, FieldSpec, PlanContext, PlanError, Request, repository, text


# Keys of a per-platform asset object: the Nix systems and the
# platforms, each system mapped to its platform.
SYSTEM_PLATFORMS = {"x86_64-linux": "linux", "aarch64-darwin": "darwin"}
PLATFORMS = ("linux", "darwin")
ASSET_KEYS = (*SYSTEM_PLATFORMS, *PLATFORMS)

Assets = templates.ReleaseTemplate | dict[str, templates.ReleaseTemplate]


def assets(value: Any) -> Assets:
    """One release template, or a non-empty object of release templates per
    system or platform (each platform named once)."""
    names = ("version", "tag")
    if isinstance(value, str):
        return templates.parse(value, names)
    if not isinstance(value, dict) or not value:
        raise DeclarationError(
            f"expected a template string or a non-empty object of templates per system or platform, found {value!r}"
        )
    result: dict[str, templates.ReleaseTemplate] = {}
    owners: dict[str, str] = {}
    for key, template in value.items():
        if key not in ASSET_KEYS:
            raise DeclarationError(f"unknown system or platform {key!r} (known: {', '.join(ASSET_KEYS)})")
        platform = SYSTEM_PLATFORMS.get(key, key)
        if platform in owners:
            raise DeclarationError(f"{owners[platform]!r} and {key!r} name the same platform")
        owners[platform] = key
        try:
            result[key] = templates.parse(template, names)
        except DeclarationError as error:
            raise DeclarationError(f"{key}: {error}") from error
    return result


def asset_details(
    release: dict[str, Any], template: templates.ReleaseTemplate, version: str, tag: str
) -> dict[str, Any]:
    """The release asset the template names: its name, size, digest and
    URL, or ``asset_missing``."""
    name = template.render(version=version, tag=tag)
    entries = release.get("assets") if isinstance(release.get("assets"), list) else []
    match = next((entry for entry in entries if isinstance(entry, dict) and entry.get("name") == name), None)
    if match is None:
        return {"asset_missing": name}
    digest = str(match.get("digest") or "").removeprefix("sha256:") or None
    return {"asset": name, "size": match.get("size"), "sha256": digest, "url": match.get("browser_download_url")}


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
        "asset": FieldSpec(assets),
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
        if release is not None and isinstance(asset, dict):
            details["assets"] = {key: asset_details(release, template, latest, tag) for key, template in asset.items()}
        elif release is not None and asset is not None:
            details.update(asset_details(release, asset, latest, tag))
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
