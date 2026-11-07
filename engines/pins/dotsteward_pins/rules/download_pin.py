"""``download-pin``: a pinned download (URL, size, digest, version).

Fields:

    at              lock path of the pin object (required unless for_each
                    is given; then it defaults to the entry and may use
                    {key})
    version_field   field holding the version (default "version")
    url_field       field holding the URL (default "url")
    size_field      field holding the size in bytes (default "size")
    sha256_field    field holding the hex SHA-256 (default "sha256")
    url_contains    text template the URL must contain (default:
                    "{.<version_field>}", the version itself)
    for_each, only_with, formats, name   (see rules/__init__.py)

Examples::

    { "kind": "download-pin", "at": "agent_tools.example",
      "version_field": "minimum_version", "url_contains": "/v{.minimum_version}/",
      "formats": { ".source_revision": "hex40" } }
    { "kind": "download-pin", "for_each": "desktop_packages",
      "only_with": "url", "version_field": "minimum_version" }

Check (labels <at>.<field>): the version is a non-empty string, the URL is
an https URL containing url_contains, the size a positive integer, the
digest 64 hex digits. A recorded ``signature`` (written by ``pins apply``,
docs/pins-engine.md) has a kind, a subject and a bundle, and the versions
lock has its signer (``trust.signers.<at>``, kind sigstore, with an identity
regular expression and an issuer) and ``trust.sigstore_root``: what the
install methods need to verify it. Check-only.
"""

from __future__ import annotations

from typing import Any, ClassVar

from ..checker import Checker
from ..lockfile import VERSIONS, LockPath, Scope, parse_path, parse_template
from . import Context, FieldSpec, Rule, string


class DownloadPin(Rule):
    kind = "download-pin"
    FOR_EACH = True
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "at": FieldSpec(parse_path),
        "version_field": FieldSpec(string, default="version"),
        "url_field": FieldSpec(string, default="url"),
        "size_field": FieldSpec(string, default="size"),
        "sha256_field": FieldSpec(string, default="sha256"),
        "url_contains": FieldSpec(parse_template),
    }

    def validate(self) -> list[str]:
        if self.values["at"] is None and self.values["for_each"] is None:
            return ["one of 'at' and 'for_each' is required"]
        return []

    def check_scope(self, ctx: Context, c: Checker, scope: Scope) -> None:
        locks = ctx.locks
        base = scope.base
        assert isinstance(base, LockPath)
        pin = locks.get(base)
        if not isinstance(pin, dict):
            raise TypeError(f"{base.text()}: expected an object")
        prefix = base.text()
        version_field = self.values["version_field"]
        url_field = self.values["url_field"]
        template = self.values["url_contains"] or parse_template("{." + version_field + "}")
        needle = locks.render(template, scope)
        url = pin.get(url_field)
        c.fmt(f"{prefix}.{version_field}", "nonempty", pin.get(version_field))
        c.fmt(f"{prefix}.{url_field}", "https-url", url)
        c.contains(f"{prefix}.{url_field}", url, needle)
        c.fmt(f"{prefix}.{self.values['size_field']}", "positive-int", pin.get(self.values["size_field"]))
        c.fmt(f"{prefix}.{self.values['sha256_field']}", "hex64", pin.get(self.values["sha256_field"]))
        if "signature" in pin:
            _check_signature(c, locks.documents.get(VERSIONS), prefix, pin["signature"])


def _check_signature(c: Checker, versions: Any, pin: str, signature: Any) -> None:
    trust = versions.get("trust") if isinstance(versions, dict) else None
    trust = trust if isinstance(trust, dict) else {}
    signers = trust.get("signers")
    signer = signers.get(pin) if isinstance(signers, dict) else None
    c.ok(
        f"{pin}.signature",
        isinstance(signature, dict)
        and signature.get("kind") in ("message", "attestation")
        and signature.get("subject") in ("asset", "member")
        and isinstance(signature.get("bundle"), dict),
        "expected a kind (message or attestation), a subject (asset or member) and a bundle",
    )
    c.ok(
        f"trust.signers.{pin}",
        isinstance(signer, dict)
        and signer.get("kind") == "sigstore"
        and isinstance(signer.get("identity_regexp"), str)
        and bool(signer.get("identity_regexp"))
        and isinstance(signer.get("issuer"), str)
        and bool(signer.get("issuer")),
        "a recorded signature needs a sigstore signer with identity_regexp and issuer",
    )
    c.ok(
        "trust.sigstore_root",
        isinstance(trust.get("sigstore_root"), dict),
        "a recorded signature needs the trusted root",
    )
