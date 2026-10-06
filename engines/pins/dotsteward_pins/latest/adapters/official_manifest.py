"""``official-manifest``: a vendor's release manifest (JSON), optionally
named by a version endpoint.

Fields:

    manifest_url    release template ({version}) of the manifest URL
                    (required); {version} needs version_url
    version_url     URL answering the newest version as plain text
    version_field   dotted field path of the version in the manifest (one
                    of version_url and version_field is required; with
                    both, they must agree)
    sha256_field    dotted field path of the hex SHA-256
    size_field      dotted field path of the size in bytes
    size_url_field  dotted field path of a download URL whose size a HEAD
                    request reads (when the manifest has no size)
    url_field       dotted field path of the download URL
    url_template    release template ({version}) of the download URL to
                    report (instead of url_field)

Row details: ``url``, ``size``, ``sha256``. A manifest that is not JSON, a
field it no longer has, a value of the wrong shape or a disagreement
between version_url and version_field is an error row.

Examples::

    { "id": "agent_tools.example.linux-x64", "adapter": "official-manifest",
      "at": "agent_tools.example.linux-x64",
      "version_url": "https://example.org/releases/stable",
      "manifest_url": "https://example.org/releases/{version}/manifest.json",
      "version_field": "version",
      "sha256_field": "platforms.linux-x64.checksum",
      "size_field": "platforms.linux-x64.size",
      "url_template": "https://example.org/releases/{version}/linux-x64/example" }
    { "id": "desktop_packages.example", "adapter": "official-manifest",
      "at": "desktop_packages.example", "current_field": "minimum_version",
      "manifest_url": "https://example.org/api/update/linux-deb-x64/stable/latest",
      "version_field": "productVersion", "sha256_field": "sha256hash",
      "size_url_field": "url",
      "url_template": "https://example.org/{version}/linux-deb-x64/stable" }
"""

from __future__ import annotations

from typing import Any, ClassVar

from ...checker import HEX64
from ...rules import string
from .. import templates
from ..model import VERSION_TEXT, Row, classify, item
from ..upstream import Upstream, UpstreamError
from . import Adapter, FieldSpec, Request, url


def field_path(document: Any, path: str) -> Any:
    """The value at a dotted path; UpstreamError when it is missing."""
    current = document
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            raise UpstreamError(f"manifest lacks {path}")
        current = current[key]
    return current


class OfficialManifest(Adapter):
    name = "official-manifest"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "manifest_url": FieldSpec(templates.parser("version"), required=True),
        "version_url": FieldSpec(url),
        "version_field": FieldSpec(string),
        "sha256_field": FieldSpec(string),
        "size_field": FieldSpec(string),
        "size_url_field": FieldSpec(string),
        "url_field": FieldSpec(string),
        "url_template": FieldSpec(templates.parser("version")),
    }

    def validate(self) -> list[str]:
        problems = []
        if self.values["version_url"] is None and self.values["version_field"] is None:
            problems.append("one of 'version_url' and 'version_field' is required")
        if self.values["manifest_url"].uses("version") and self.values["version_url"] is None:
            problems.append("'manifest_url' uses {version}, which needs 'version_url'")
        problems.extend(self.exclusive("size_field", "size_url_field"))
        problems.extend(self.exclusive("url_field", "url_template"))
        return problems

    def default_source(self, request: Request) -> str:
        return self.values["version_url"] or self.values["manifest_url"].source

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        version = None
        version_url = self.values["version_url"]
        if version_url is not None:
            text = upstream.http_text(version_url).strip()
            if not VERSION_TEXT.fullmatch(text):
                raise UpstreamError(f"{version_url} answered not a version: {text[:40]!r}")
            version = text
        manifest_url = self.values["manifest_url"].render(version=version or "")
        manifest = upstream.http_json(manifest_url)
        version_field = self.values["version_field"]
        if version_field is not None:
            found = field_path(manifest, version_field)
            if not isinstance(found, str) or not VERSION_TEXT.fullmatch(found):
                raise UpstreamError(f"manifest {version_field} is not a version: {found!r}")
            if version is not None and found != version:
                raise UpstreamError(f"manifest version {found} differs from {version} ({version_url})")
            version = found
        assert version is not None

        sha256 = None
        if self.values["sha256_field"] is not None:
            sha256 = field_path(manifest, self.values["sha256_field"])
            if not isinstance(sha256, str) or not HEX64.fullmatch(sha256):
                raise UpstreamError(f"manifest {self.values['sha256_field']} is not a hex SHA-256: {sha256!r}")
        size = None
        if self.values["size_field"] is not None:
            size = field_path(manifest, self.values["size_field"])
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                raise UpstreamError(f"manifest {self.values['size_field']} is not a size: {size!r}")
        elif self.values["size_url_field"] is not None:
            target = field_path(manifest, self.values["size_url_field"])
            if not isinstance(target, str) or "://" not in target:
                raise UpstreamError(f"manifest {self.values['size_url_field']} is not a URL: {target!r}")
            size = upstream.http_head(target).size
        download = None
        if self.values["url_template"] is not None:
            download = self.values["url_template"].render(version=version)
        elif self.values["url_field"] is not None:
            download = field_path(manifest, self.values["url_field"])
            if not isinstance(download, str):
                raise UpstreamError(f"manifest {self.values['url_field']} is not a URL: {download!r}")
        return [
            item(
                request.id,
                self.name,
                request.current,
                version,
                classify(request.current, version, request.held),
                self.source_of(request),
                url=download,
                size=size,
                sha256=sha256,
                note=request.note,
            )
        ]
