"""Authenticity of a download the writer moves a pin to (docs/pins-engine.md).

Discovery, the addresses probed at once, each bounded by a timeout and the
whole by DISCOVERY_BUDGET:

1. a Sigstore bundle published next to the file: ``<url>.sigstore.json``,
   ``<url>.sigstore``, ``<url>.bundle``, and for an archive the same names
   after the archive without its extension: a signature of the member a
   component installs from the pin (``install.member``), checked by its full
   path in the archive whose digest the pin records;
2. a GitHub artifact attestation of the digest, when the pin's repository is
   known (``gh api repos/<repo>/attestations/sha256:<digest>``, then
   ``gh attestation download``): build provenance logged in the public
   transparency log.

Only "no such file" (HTTP 403, 404, 410) means not published; a lookup without
an answer is no verdict (``DiscoveryIncomplete`` for a signed source, the group
waits for the next run; an unsigned source moves, labelled so).

What is found is verified by cosign against the trusted root, offline, with the
exact identity of the certificate. The trusted root comes from
``gh attestation trusted-root`` (TUF-verified by the GitHub CLI), else the one
the lock recorded. Trust on first use: the first verified signer of a pin, which
must be a workflow of the pin's repository when it is known, is recorded in
``trust.signers`` as an identity regular expression (the tag generalized) and
an OIDC issuer; every later signature must match it, and the identity's tag must
be that of the release the pin moves to. Each refusal is a review item
(``Waits``), and the pin stays. A source without any signature moves (no minimum
release age, T8-a); its signer entry says ``unsigned``.

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
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .. import trust as trust_rules
from .tools import BUILD_TIMEOUT, GroupFailure, Tools, Waits

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
# What Nix and the GitHub CLI say when the server answers that there is no such file.
_ABSENT = re.compile(r"HTTP error (?:403|404|410)\b")
_GH_ABSENT = re.compile(r"HTTP 404\b|Not Found")


@dataclass
class Candidate:
    """A bundle found for the download: what it signs and how it was found."""

    bundle: dict[str, Any]
    subject: str  # "asset" or "member"
    member: str | None = None
    member_path: Path | None = None
    origin: str = ""


@dataclass
class Release:
    """What the writer moves the pin to: the file, the version and where it comes from."""

    pin: str
    url: str
    digest: str
    version: str
    tag: str | None = None
    repository: str | None = None
    # The archive members the components install from this pin (install.member).
    members: tuple[str, ...] = ()


class DiscoveryIncomplete(Exception):
    """A signature lookup got no answer (no network, a server error, a timeout):
    no verdict, so the pin waits for the next run."""


@dataclass
class Finding:
    """The authenticity of one moved download."""

    status: str  # "sigstore" or "unsigned"
    signature: dict[str, Any] | None = None
    signer: dict[str, Any] | None = None
    root: dict[str, Any] | None = None
    first_use: bool = False
    # An unsigned source moved although a lookup got no answer.
    incomplete: bool = False
    # The repository whose later releases the local APT bridge serves unsigned.
    bridge: str | None = None

    def report(self, move_id: str) -> dict[str, Any]:
        entry: dict[str, Any] = {"id": move_id, "status": self.status}
        if self.signature is not None:
            entry["identity"] = self.signature["identity"]
            entry["first_use"] = self.first_use
        if self.incomplete:
            entry["discovery"] = "incomplete"
        if self.bridge is not None:
            entry["apt_bridge"] = "unsigned"
        return entry

    def label(self) -> str:
        if self.signature is None:
            text = "unsigned, signature discovery incomplete" if self.incomplete else "unsigned"
        else:
            text = f"sigstore: {self.signature['identity']}"
            if self.first_use:
                text += ", trusted on first use"
        if self.bridge is not None:
            text += f"; the local APT bridge serves later releases of {self.bridge} unsigned"
        return text


@dataclass
class Authenticity:
    tools: Tools
    work: Path
    _root: dict[str, Any] | None = None
    _root_read: bool = False
    _deadline: float = field(default=0.0)
    _unknown: list[str] = field(default_factory=list)

    # -- the decision --

    def examine(self, versions: dict[str, Any], release: Release) -> Finding:
        trust = _object(versions.get("trust"))
        signer = _object(_object(trust.get("signers")).get(release.pin)) or None
        pinned = signer if signer is not None and signer.get("kind") == "sigstore" else None
        self._deadline = time.monotonic() + DISCOVERY_BUDGET
        self._unknown = []
        candidates = self._bundles(release) or self._attestations(release)
        if not candidates:
            if self._unknown:
                if pinned is not None:
                    unanswered = "; ".join(self._unknown[:3])
                    raise DiscoveryIncomplete(
                        f"signature discovery got no answer ({unanswered}); the pin waits for the next run"
                    )
                return Finding(
                    "unsigned", signer=signer or {"kind": "unsigned", "first_seen": _today()}, incomplete=True
                )
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
        signature = _signature(candidate, release.digest)
        identity, issuer = signature["identity"], _issuer(candidate.bundle)
        if pinned is not None:
            regexp, expected = str(pinned.get("identity_regexp") or ""), str(pinned.get("issuer") or "")
            if not trust_rules.matches(regexp, identity) or issuer != expected:
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
            new_signer = {
                "kind": "sigstore",
                "identity_regexp": trust_rules.identity_regexp(identity),
                "issuer": issuer,
                "first_seen": _today(),
            }
        # cosign verifies the exact identity of the certificate.
        error = self._verify(signature, candidate, release.digest, root, identity, issuer)
        if error is not None:
            raise Waits("authenticity-failed", error=error, identity=identity, origin=candidate.origin)
        tag = trust_rules.tag_of(identity)
        if tag is not None and not _names_release(tag, release):
            raise Waits(
                "authenticity-identity-version",
                reason="the signature is of another release than the one the pin moves to",
                identity=identity,
                tag=release.tag or release.version,
            )
        if pinned is None and release.repository and not trust_rules.of_repository(identity, release.repository):
            raise Waits(
                "authenticity-first-use-foreign",
                reason="the first signer is no workflow of the pin's repository",
                identity=identity,
                repository=release.repository,
            )
        return Finding("sigstore", signature=signature, signer=new_signer, root=root, first_use=pinned is None)

    # -- discovery --

    def _remaining(self) -> int:
        return max(1, min(STEP_TIMEOUT, int(self._deadline - time.monotonic())))

    def _probe(self, url: str) -> Path | None:
        """The file at URL, downloaded by Nix; None when the server says it is not
        there; an address without an answer is noted in _unknown."""
        if time.monotonic() >= self._deadline:
            self._unknown.append(f"{url}: no time left")
            return None
        try:
            result = self.tools.run([*NIX, "store", "prefetch-file", "--json", url], timeout=self._remaining())
        except GroupFailure as failure:
            self._unknown.append(f"{url}: {failure}")
            return None
        if result.returncode != 0:
            if not _ABSENT.search(result.stderr):
                self._unknown.append(f"{url}: {_last_line(result.stderr)}")
            return None
        try:
            return Path(json.loads(result.stdout)["storePath"])
        except (ValueError, KeyError, TypeError):
            self._unknown.append(f"{url}: nix answered no store path")
            return None

    def _artifact(self, release: Release) -> Path:
        """The file of the pin, downloaded (or found in the store) by Nix, with the digest
        of the pin: the bytes a signature of it, or of its member, is checked on."""
        text = self.tools.nix("store", "prefetch-file", "--json", release.url, timeout=BUILD_TIMEOUT)
        try:
            path = Path(json.loads(text)["storePath"])
        except (ValueError, KeyError, TypeError) as error:
            raise GroupFailure(f"nix store prefetch-file answered {text[:200]!r}") from error
        if _sha256(path) != release.digest:
            raise GroupFailure(f"{release.url} does not have the digest of the pin")
        return path

    def _bundles(self, release: Release) -> list[Candidate]:
        plain = release.url.split("?", 1)[0].split("#", 1)[0]
        bases: list[tuple[str, str | None]] = [(plain, None)]
        archive = next((ext for ext in ARCHIVES if plain.endswith(ext)), None)
        member = _member_of(release.members, plain[: -len(archive)] if archive else "")
        if archive and member is not None:
            bases.append((plain[: -len(archive)], member))
        addresses = [(base + suffix, member) for base, member in bases for suffix in SUFFIXES]
        # Every address at once: a slow network costs one timeout, not one per address.
        with ThreadPoolExecutor(max_workers=len(addresses)) as pool:
            paths = list(pool.map(self._probe, [address for address, _ in addresses]))
        found: list[Candidate] = []
        archive_path: Path | None = None
        for (address, signed_member), path in zip(addresses, paths, strict=True):
            if path is None:
                continue
            bundle = _json(path.read_bytes())
            if not _is_bundle(bundle):
                # A server that answers every path (a page, another document): no
                # signature. Only a bundle that does not verify stops the pin.
                continue
            if signed_member is None:
                found.append(Candidate(bundle, "asset", origin=address))
                continue
            if archive_path is None:
                archive_path = self._artifact(release)
            copy = self._member(archive_path, archive or "", signed_member, address)
            found.append(Candidate(bundle, "member", signed_member, copy, origin=address))
        # The file's own bundle first, then the member's.
        return sorted(found, key=lambda candidate: candidate.subject != "asset")

    def _member(self, archive: Path, kind: str, name: str, origin: str) -> Path:
        """A copy of the archive member NAME (its full path), which the archive must
        hold exactly once, as a regular file reached through no link."""

        def fail(error: str) -> Waits:
            return Waits("authenticity-failed", error=error, origin=origin)

        target = self.work / f"member-{hashlib.sha256(f'{archive}:{name}'.encode()).hexdigest()[:16]}"
        prefixes = {"/".join(name.split("/")[:count]) for count in range(1, name.count("/") + 1)}
        try:
            if kind == ".zip":
                with zipfile.ZipFile(archive) as bundle:
                    listed = [info for info in bundle.infolist() if _normal(info.filename) == name]
                    if len(listed) != 1 or listed[0].is_dir():
                        raise fail(_count_error(name, len(listed)))
                    if (listed[0].external_attr >> 16) & 0o170000 == 0o120000:
                        raise fail(f"the archive member {name} is a link")
                    target.write_bytes(bundle.read(listed[0]))
                    return target
            with tarfile.open(archive, "r:*") as tar:
                members = tar.getmembers()
                if any(_normal(entry.name) in prefixes and not entry.isdir() for entry in members):
                    raise fail(f"the path of the archive member {name} goes through a link")
                entries = [entry for entry in members if _normal(entry.name) == name]
                if len(entries) != 1:
                    raise fail(_count_error(name, len(entries)))
                if not entries[0].isreg():
                    raise fail(f"the archive member {name} is not a regular file")
                handle = tar.extractfile(entries[0])
                if handle is None:
                    raise fail(f"the archive member {name} cannot be read")
                target.write_bytes(handle.read())
                return target
        except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError) as error:
            raise fail(f"the archive cannot be read ({error})") from error

    def _attestations(self, release: Release) -> list[Candidate]:
        repository = release.repository
        if not repository:
            return []
        if time.monotonic() >= self._deadline:
            self._unknown.append("attestations: no time left")
            return []
        try:
            listed = self.tools.run(
                ["gh", "api", f"repos/{repository}/attestations/sha256:{release.digest}"], timeout=self._remaining()
            )
        except GroupFailure as failure:
            self._unknown.append(f"attestations of {repository}: {failure}")
            return []
        if listed.returncode != 0:
            if not _GH_ABSENT.search(listed.stderr):
                self._unknown.append(f"attestations of {repository}: {_last_line(listed.stderr)}")
            return []
        document = _json(listed.stdout.encode())
        if not isinstance(document, dict) or not document.get("attestations"):
            return []
        artifact = self._artifact(release)
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            try:
                result = self.tools.run(
                    ["gh", "attestation", "download", str(artifact), "--repo", repository],
                    timeout=self._remaining(),
                    cwd=Path(directory),
                )
            except GroupFailure as failure:
                self._unknown.append(f"attestation download: {failure}")
                return []
            if result.returncode != 0:
                self._unknown.append(f"attestation download: {_last_line(result.stderr)}")
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
                found.append(
                    Candidate(bundle, "asset", origin=f"attestation of sha256:{release.digest} in {repository}")
                )
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
        identity: str,
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
                "--certificate-identity",
                identity,
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


def _names_release(tag: str, release: Release) -> bool:
    """TAG is the release's tag, or names its version (without what precedes the
    first digit, as in v1.2.0 or rust-v1.2.0) when the row names no tag."""
    if release.tag:
        return tag == release.tag
    digits = re.search(r"[0-9]", tag)
    return digits is not None and tag[digits.start() :] == release.version.split("+", 1)[0]


def _member_of(members: tuple[str, ...], stem: str) -> str | None:
    """The member a bundle named after the archive (STEM) signs: the one member the
    components install from the pin, or among several the one named like the archive."""
    if len(members) == 1:
        return members[0]
    named = [member for member in members if member.rsplit("/", 1)[-1] == stem.rsplit("/", 1)[-1]]
    return named[0] if len(named) == 1 else None


def _normal(name: str) -> str:
    return name.removeprefix("./").rstrip("/")


def _count_error(name: str, count: int) -> str:
    return f"the archive holds {name} more than once" if count else f"the archive does not hold {name}"


def _last_line(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else "no message"


def _is_bundle(value: Any) -> bool:
    """VALUE has what a signature bundle carries: a Sigstore bundle's message
    signature or DSSE envelope, or a legacy cosign bundle's signature."""
    return isinstance(value, dict) and any(
        key in value for key in ("messageSignature", "dsseEnvelope", "base64Signature")
    )


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
