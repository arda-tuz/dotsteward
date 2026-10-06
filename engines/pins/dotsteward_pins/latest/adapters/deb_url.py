"""``deb-url``: a vendor download link that always serves the newest
package, for vendors without a package index.

Fields:

    latest_url       URL of the newest package (required); redirects are
                     followed
    version_pattern  regular expression searched in the final URL (after
                     redirects); its group named "version", or its first
                     group, is the version. Default: the Debian file name
                     "<name>_<version>_<arch>.deb" of the Content-Disposition
                     header or the final URL's last segment
    url_template     release template ({version}) of the download URL to
                     report; default the final URL

Query: one HEAD request (it stays HEAD across redirects, nothing is
downloaded). Row details: ``file``, ``url``, ``size`` (Content-Length) and
``last_modified``. No version in the answer is an error row.

Example::

    { "id": "desktop_packages.example", "adapter": "deb-url",
      "latest_url": "https://example.org/download/latest/linux-deb",
      "url_template": "https://example.org/pool/example_{version}_amd64.deb" }
"""

from __future__ import annotations

import re
from typing import Any, ClassVar

from ...lockfile import DeclarationError
from .. import templates
from ..model import VERSION_TEXT, Row, classify, item
from ..upstream import Upstream, UpstreamError
from . import Adapter, FieldSpec, Request, regex, url

DEBIAN_FILE = re.compile(r"[^_/]+_(?P<version>[^_/]+)_[^_/]+\.deb")


def version_pattern(value: Any) -> re.Pattern[str]:
    pattern = regex(value)
    if pattern.groups == 0:
        raise DeclarationError("needs one group or a group named version")
    return pattern


class DebUrl(Adapter):
    name = "deb-url"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "latest_url": FieldSpec(url, required=True),
        "version_pattern": FieldSpec(version_pattern),
        "url_template": FieldSpec(templates.parser("version")),
    }

    def default_source(self, request: Request) -> str:
        return self.values["latest_url"]

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        head = upstream.http_head(self.values["latest_url"])
        file_name = head.file_name
        pattern = self.values["version_pattern"]
        version = None
        if pattern is not None:
            match = pattern.search(head.url)
            if match is not None:
                version = match.group("version") if "version" in pattern.groupindex else match.group(1)
            where = head.url
        else:
            match = DEBIAN_FILE.fullmatch(file_name)
            version = match.group("version") if match else None
            where = file_name
        if not version or not VERSION_TEXT.fullmatch(version):
            raise UpstreamError(f"cannot read a version from {where}")
        template = self.values["url_template"]
        download = template.render(version=version) if template is not None else head.url
        return [
            item(
                request.id,
                self.name,
                request.current,
                version,
                classify(request.current, version, request.held),
                self.source_of(request),
                file=file_name,
                url=download,
                size=head.size,
                last_modified=head.headers.get("Last-Modified"),
                note=request.note,
            )
        ]
