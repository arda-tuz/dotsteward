"""Authenticity of a download the writer moves a pin to (docs/pins-engine.md).

Discovery, each step bounded by a timeout and the whole by DISCOVERY_BUDGET:

1. a Sigstore bundle published next to the file: ``<url>.sigstore.json``,
   ``<url>.sigstore``, ``<url>.bundle``, and for an archive the same names
   after its member (``<url without .tar.gz>.sigstore``: a signature of the
   file inside, as GitHub release workflows publish it);
2. a GitHub artifact attestation of the digest, when the pin's repository is
   known (``gh api repos/<repo>/attestations/sha256:<digest>``, then
   ``gh attestation download``): build provenance logged in the public
   transparency log.

What is found is verified by cosign against the trusted root, offline. The
trusted root comes from ``gh attestation trusted-root`` (TUF-verified by the
GitHub CLI), else the one the lock recorded. Trust on first use: the first
verified signer of a pin is recorded in ``trust.signers`` as an identity
regular expression (the tag generalized) and an OIDC issuer; every later
signature must match it. A signer that does not match, a signature that does
not verify, a signed source that stops signing and a signature without a
trusted root are review items (``Waits``), and the pin stays. A source without
any signature moves (no minimum release age, T8-a); its signer entry says
``unsigned``.

The recorded signature is the bundle cosign verified (a legacy cosign bundle
is converted to a v0.1 Sigstore bundle first), so an install verifies it again
from the lock, without network.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import json
import re
import tarfile
import tempfile
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .tools import GroupFailure, Tools, Waits

SUFFIXES = (".sigstore.json", ".sigstore", ".bundle")
# The archives whose member the writer can read (the methods extract the same).
ARCHIVES = (".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar", ".zip")
PROVENANCE = "https://slsa.dev/provenance/v1"
STEP_TIMEOUT = 60
VERIFY_TIMEOUT = 120
DISCOVERY_BUDGET = 180
BUNDLE_V01 = "application/vnd.dev.sigstore.bundle+json;version=0.1"
_SAN = bytes.fromhex("0603551d11")
_ISSUER_V1 = bytes.fromhex("060a2b0601040183bf300101")
_ISSUER_V2 = bytes.fromhex("060a2b0601040183bf300108")
_SPECIAL = set("\\.^$*+?()[]{}|")


@dataclass
class Candidate:
    """A bundle found for the download: what it signs and how it was found."""

    bundle: dict[str, Any]
    subject: str  # "asset" or "member"
    member: str | None = None
    member_path: Path | None = None
    origin: str = ""


@dataclass
class Finding:
    """The authenticity of one moved download."""

    status: str  # "sigstore" or "unsigned"
    signature: dict[str, Any] | None = None
    signer: dict[str, Any] | None = None
    root: dict[str, Any] | None = None
    first_use: bool = False

    def report(self, move_id: str) -> dict[str, Any]:
        entry: dict[str, Any] = {"id": move_id, "status": self.status}
        if self.signature is not None:
            entry["identity"] = self.signature["identity"]
            entry["first_use"] = self.first_use
        return entry

    def label(self) -> str:
        if self.signature is None:
            return "unsigned"
        text = f"sigstore: {self.signature['identity']}"
        return f"{text}, trusted on first use" if self.first_use else text


@dataclass
class Authenticity:
    tools: Tools
    work: Path
    _root: dict[str, Any] | None = None
    _root_read: bool = False
    _deadline: float = field(default=0.0)

    # -- the decision --

    def examine(self, versions: dict[str, Any], pin: str, url: str, digest: str, repository: str | None) -> Finding:
        trust = _object(versions.get("trust"))
        signer = _object(_object(trust.get("signers")).get(pin)) or None
        pinned = signer if signer is not None and signer.get("kind") == "sigstore" else None
        self._deadline = time.monotonic() + DISCOVERY_BUDGET
        candidates = self._bundles(url) or self._attestations(url, digest, repository)
        if not candidates:
            if pinned is not None:
                raise Waits(
                    "authenticity-signature-missing",
                    reason="the source was signed and this release has no signature next to it and no attestation",
                    identity_regexp=pinned.get("identity_regexp"),
                )
            return Finding("unsigned", signer=signer or {"kind": "unsigned", "first_seen": _today()})
        candidate = candidates[0]
        root = self._trusted_root(trust)
        if root is None:
            raise Waits("authenticity-no-trusted-root", reason="no trusted root is recorded and none could be read")
        signature = _signature(candidate, digest)
        identity, issuer = signature["identity"], _issuer(candidate.bundle)
        if pinned is not None:
            regexp, expected = str(pinned.get("identity_regexp") or ""), str(pinned.get("issuer") or "")
            if not _matches(regexp, identity) or issuer != expected:
                raise Waits(
                    "authenticity-signer-changed",
                    identity=identity,
                    issuer=issuer,
                    identity_regexp=regexp,
                    expected_issuer=expected,
                )
            new_signer = dict(pinned)
        else:
            if not issuer:
                raise Waits("authenticity-failed", error="the certificate names no OIDC issuer", identity=identity)
            regexp, expected = identity_regexp(identity), issuer
            new_signer = {"kind": "sigstore", "identity_regexp": regexp, "issuer": issuer, "first_seen": _today()}
        error = self._verify(signature, candidate, digest, root, regexp, expected)
        if error is not None:
            raise Waits("authenticity-failed", error=error, identity=identity, origin=candidate.origin)
        return Finding("sigstore", signature=signature, signer=new_signer, root=root, first_use=pinned is None)

    # -- discovery --

    def _remaining(self) -> int:
        return max(1, min(STEP_TIMEOUT, int(self._deadline - time.monotonic())))

    def _expired(self) -> bool:
        return time.monotonic() >= self._deadline

    def _fetch(self, url: str) -> Path | None:
        """The file at URL, downloaded by Nix; None when it is not there."""
        if self._expired():
            return None
        try:
            result = self.tools.run([*NIX, "store", "prefetch-file", "--json", url], timeout=self._remaining())
        except GroupFailure:
            return None
        if result.returncode != 0:
            return None
        try:
            return Path(json.loads(result.stdout)["storePath"])
        except (ValueError, KeyError, TypeError):
            return None

    def _bundles(self, url: str) -> list[Candidate]:
        plain = url.split("?", 1)[0].split("#", 1)[0]
        bases: list[tuple[str, str | None]] = [(plain, None)]
        archive = next((ext for ext in ARCHIVES if plain.endswith(ext)), None)
        if archive:
            stem = plain[: -len(archive)]
            bases.append((stem, stem.rsplit("/", 1)[-1]))
        found: list[Candidate] = []
        archive_path: Path | None = None
        for base, member in bases:
            for suffix in SUFFIXES:
                path = self._fetch(base + suffix)
                if path is None:
                    continue
                bundle = _json(path.read_bytes())
                if bundle is None:
                    raise Waits("authenticity-failed", error=f"{base + suffix} is not JSON", origin=base + suffix)
                if member is None:
                    found.append(Candidate(bundle, "asset", origin=base + suffix))
                    continue
                if archive_path is None:
                    archive_path = self._fetch(url)
                    if archive_path is None:
                        raise GroupFailure(f"cannot download {url} to verify the signature of its member")
                extracted = self._member(archive_path, archive or "", member)
                if extracted is None:
                    raise Waits(
                        "authenticity-failed",
                        error=f"{base + suffix} signs {member}, which the archive does not hold",
                        origin=base + suffix,
                    )
                found.append(Candidate(bundle, "member", extracted[0], extracted[1], origin=base + suffix))
            if found:
                return found
        return found

    def _member(self, archive: Path, kind: str, name: str) -> tuple[str, Path] | None:
        """The first regular file of ARCHIVE whose name ends in NAME, as (member, copy)."""
        target = self.work / f"member-{hashlib.sha256(str(archive).encode()).hexdigest()[:16]}"
        try:
            if kind == ".zip":
                with zipfile.ZipFile(archive) as bundle:
                    for entry in bundle.infolist():
                        if not entry.is_dir() and entry.filename.rsplit("/", 1)[-1] == name:
                            target.write_bytes(bundle.read(entry))
                            return entry.filename, target
                return None
            with tarfile.open(archive, "r:*") as tar:
                for member in tar:
                    if member.isreg() and member.name.rsplit("/", 1)[-1] == name:
                        handle = tar.extractfile(member)
                        if handle is None:
                            return None
                        target.write_bytes(handle.read())
                        return member.name.removeprefix("./"), target
        except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError):
            return None
        return None

    def _attestations(self, url: str, digest: str, repository: str | None) -> list[Candidate]:
        if not repository or self._expired():
            return []
        try:
            listed = self.tools.run(
                ["gh", "api", f"repos/{repository}/attestations/sha256:{digest}"], timeout=self._remaining()
            )
        except GroupFailure:
            return []
        document = _json(listed.stdout.encode()) if listed.returncode == 0 else None
        if not isinstance(document, dict) or not document.get("attestations"):
            return []
        artifact = self._fetch(url)
        if artifact is None:
            return []
        if _sha256(artifact) != digest:
            raise GroupFailure(f"{url} does not have the digest of the pin")
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            try:
                result = self.tools.run(
                    ["gh", "attestation", "download", str(artifact), "--repo", repository],
                    timeout=self._remaining(),
                    cwd=Path(directory),
                )
            except GroupFailure:
                return []
            if result.returncode != 0:
                return []
            lines = [
                line
                for path in sorted(Path(directory).glob("*.jsonl"))
                for line in path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
        found = []
        for line in lines:
            bundle = _json(line.encode())
            if not isinstance(bundle, dict) or _predicate(bundle) != PROVENANCE:
                continue
            entries = (bundle.get("verificationMaterial") or {}).get("tlogEntries")
            if entries:
                found.append(Candidate(bundle, "asset", origin=f"attestation of sha256:{digest} in {repository}"))
        return found

    # -- verification --

    def _trusted_root(self, trust: dict[str, Any]) -> dict[str, Any] | None:
        if not self._root_read:
            self._root_read = True
            try:
                result = self.tools.run(["gh", "attestation", "trusted-root"], timeout=STEP_TIMEOUT)
            except GroupFailure:
                result = None
            if result is not None and result.returncode == 0:
                self._root = _merge_roots(result.stdout)
        if self._root is not None:
            return self._root
        recorded = trust.get("sigstore_root")
        return recorded if isinstance(recorded, dict) else None

    def _verify(
        self,
        signature: dict[str, Any],
        candidate: Candidate,
        digest: str,
        root: dict[str, Any],
        regexp: str,
        issuer: str,
    ) -> str | None:
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            home = Path(directory)
            (home / "bundle.json").write_text(json.dumps(signature["bundle"]), encoding="utf-8")
            (home / "root.json").write_text(json.dumps(root), encoding="utf-8")
            command = ["cosign"]
            if signature["kind"] == "attestation":
                command += ["verify-blob-attestation", "--type", signature["predicate_type"]]
            else:
                command += ["verify-blob"]
            command += [
                "--trusted-root",
                str(home / "root.json"),
                "--bundle",
                str(home / "bundle.json"),
                "--certificate-identity-regexp",
                regexp,
                "--certificate-oidc-issuer",
                issuer,
            ]
            if candidate.member_path is not None:
                command.append(str(candidate.member_path))
            elif signature["kind"] == "attestation":
                command += ["--digest", digest, "--digestAlg", "sha256"]
            else:
                command.append(f"sha256:{digest}")
            result = self.tools.run(["env", f"HOME={home}", *command], timeout=VERIFY_TIMEOUT)
        if result.returncode == 0:
            return None
        errors = [line.removeprefix("Error: ") for line in result.stderr.splitlines() if line.startswith("Error: ")]
        if errors:
            return errors[0]
        rest = result.stderr.strip().splitlines()
        return rest[-1] if rest else f"cosign exit status {result.returncode}"


NIX = ("nix", "--extra-experimental-features", "nix-command flakes")


def identity_regexp(identity: str) -> str:
    """The regular expression that pins IDENTITY: escaped, and after
    ``@refs/tags/`` every run of digits generalized, so the next release of the
    same workflow matches and nothing else does."""
    head, separator, tag = identity.partition("@refs/tags/")
    if not separator:
        return f"^{_escape(identity)}$"
    return f"^{_escape(head + separator)}{re.sub(r'[0-9]+', '[0-9]+', _escape(tag))}$"


def _escape(text: str) -> str:
    return "".join(f"\\{char}" if char in _SPECIAL else char for char in text)


def _matches(regexp: str, identity: str) -> bool:
    try:
        return re.search(regexp, identity) is not None
    except re.error:
        # A hand-written expression Python does not read: cosign decides.
        return True


def _object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _today() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")


def _json(data: bytes) -> Any:
    try:
        return json.loads(data)
    except ValueError:
        return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _merge_roots(text: str) -> dict[str, Any] | None:
    """The trusted roots of TEXT (JSON values, one per line or pretty-printed)
    that have a transparency log, merged into one."""
    decoder = json.JSONDecoder()
    position, roots = 0, []
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if position >= len(text):
            break
        try:
            value, position = decoder.raw_decode(text, position)
        except ValueError:
            return None
        if isinstance(value, dict) and value.get("tlogs"):
            roots.append(value)
    if not roots:
        return None
    merged = dict(roots[0])
    for other in roots[1:]:
        for key in ("tlogs", "certificateAuthorities", "ctlogs", "timestampAuthorities"):
            merged[key] = [*merged.get(key, []), *other.get(key, [])]
    return merged


def _predicate(bundle: dict[str, Any]) -> str | None:
    envelope = bundle.get("dsseEnvelope")
    if not isinstance(envelope, dict):
        return None
    statement = _json(base64.b64decode(str(envelope.get("payload", "")) + "=="))
    return statement.get("predicateType") if isinstance(statement, dict) else None


def _certificate(bundle: dict[str, Any]) -> bytes:
    """The DER signing certificate of a bundle (v0.1 to v0.3, or legacy cosign)."""
    try:
        if "cert" in bundle:
            text = base64.b64decode(bundle["cert"]).decode("ascii")
            return base64.b64decode("".join(line for line in text.splitlines() if not line.startswith("-----")))
        material = bundle["verificationMaterial"]
        if "certificate" in material:
            return base64.b64decode(material["certificate"]["rawBytes"])
        return base64.b64decode(material["x509CertificateChain"]["certificates"][0]["rawBytes"])
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise Waits("authenticity-failed", error=f"the bundle has no signing certificate ({error})") from error


def _signature(candidate: Candidate, digest: str) -> dict[str, Any]:
    """The signature object a pin records for CANDIDATE."""
    bundle = candidate.bundle
    if "base64Signature" in bundle:
        subject = _sha256(candidate.member_path) if candidate.member_path is not None else digest
        bundle = _from_legacy(bundle, subject)
    identity = _identity(_certificate(bundle))
    if not identity:
        raise Waits("authenticity-failed", error="the certificate names no identity", origin=candidate.origin)
    signature: dict[str, Any] = {"kind": "message", "subject": candidate.subject}
    if candidate.member is not None:
        signature["member"] = candidate.member
    if "dsseEnvelope" in bundle:
        predicate = _predicate(bundle)
        if not predicate:
            raise Waits("authenticity-failed", error="the attestation has no predicate type", origin=candidate.origin)
        signature.update(kind="attestation", predicate_type=predicate)
    elif "messageSignature" not in bundle:
        raise Waits("authenticity-failed", error="the bundle has no signature", origin=candidate.origin)
    signature.update(identity=identity, bundle=bundle)
    return signature


def _from_legacy(legacy: dict[str, Any], digest: str) -> dict[str, Any]:
    """A legacy cosign bundle (signature, certificate, Rekor bundle) as the
    v0.1 Sigstore bundle cosign verifies against a trusted root."""
    try:
        rekor = legacy["rekorBundle"]
        payload = rekor["Payload"]
        body = json.loads(base64.b64decode(payload["body"]))
        return {
            "mediaType": BUNDLE_V01,
            "verificationMaterial": {
                "x509CertificateChain": {
                    "certificates": [{"rawBytes": base64.b64encode(_certificate(legacy)).decode()}]
                },
                "tlogEntries": [
                    {
                        "logIndex": str(int(payload["logIndex"])),
                        "logId": {"keyId": base64.b64encode(bytes.fromhex(payload["logID"])).decode()},
                        "kindVersion": {"kind": str(body["kind"]), "version": str(body["apiVersion"])},
                        "integratedTime": str(int(payload["integratedTime"])),
                        "inclusionPromise": {"signedEntryTimestamp": str(rekor["SignedEntryTimestamp"])},
                        "canonicalizedBody": str(payload["body"]),
                    }
                ],
            },
            "messageSignature": {
                "messageDigest": {"algorithm": "SHA2_256", "digest": base64.b64encode(bytes.fromhex(digest)).decode()},
                "signature": str(legacy["base64Signature"]),
            },
        }
    except (KeyError, TypeError, ValueError) as error:
        raise Waits("authenticity-failed", error=f"the legacy cosign bundle is incomplete ({error})") from error


# -- the few DER fields the decision reads (cosign verifies the certificate) --


def _tlv(data: bytes, offset: int) -> tuple[int, int, int]:
    """(tag, start of the value, end of the value) of the DER element at OFFSET."""
    tag, length = data[offset], data[offset + 1]
    offset += 2
    if length & 0x80:
        count = length & 0x7F
        length = int.from_bytes(data[offset : offset + count], "big")
        offset += count
    return tag, offset, offset + length


def _children(data: bytes, start: int, end: int) -> list[tuple[int, int, int, int]]:
    """(tag, element start, value start, value end) of the elements in [start, end)."""
    found = []
    while start < end:
        tag, value, stop = _tlv(data, start)
        found.append((tag, start, value, stop))
        start = stop
    return found


def _extensions(der: bytes) -> dict[bytes, bytes]:
    """The extension values of a certificate, by the DER of their OID."""
    try:
        _, cert_start, _cert_end = _tlv(der, 0)
        _, tbs_start, tbs_end = _tlv(der, cert_start)
        found: dict[bytes, bytes] = {}
        for tag, _element, value, _stop in _children(der, tbs_start, tbs_end):
            if tag != 0xA3:
                continue
            _, list_start, list_end = _tlv(der, value)
            for _tag, _start, ext_start, ext_end in _children(der, list_start, list_end):
                parts = _children(der, ext_start, ext_end)
                oid = der[parts[0][1] : parts[0][3]]
                _octet_tag, _o, octet_start, octet_end = parts[-1]
                found[oid] = der[octet_start:octet_end]
        return found
    except IndexError:
        return {}


def _identity(der: bytes) -> str:
    """The first URI (else e-mail) subject alternative name of a certificate."""
    value = _extensions(der).get(_SAN)
    if value is None:
        return ""
    try:
        _, start, end = _tlv(value, 0)
        names = _children(value, start, end)
    except IndexError:
        return ""
    for wanted in (0x86, 0x81):
        for tag, _element, name_start, name_end in names:
            if tag == wanted:
                return value[name_start:name_end].decode("ascii", "replace")
    return ""


def _issuer(bundle: dict[str, Any]) -> str:
    """The OIDC issuer a Fulcio certificate records (extension v2, else v1)."""
    extensions = _extensions(_certificate(bundle))
    value = extensions.get(_ISSUER_V2)
    if value:
        try:
            _, start, end = _tlv(value, 0)
            return value[start:end].decode("utf-8", "replace")
        except IndexError:
            return ""
    legacy = extensions.get(_ISSUER_V1)
    return legacy.decode("utf-8", "replace") if legacy else ""
