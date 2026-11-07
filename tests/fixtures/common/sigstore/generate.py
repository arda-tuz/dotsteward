"""Writes the synthetic sigstore fixtures of this directory.

Not run by the tests: the files it writes are committed, and the private keys
it makes exist only while it runs. It needs Python with the `cryptography`
package, for example:

    nix shell --impure --expr \
      'with import <nixpkgs> {}; python3.withPackages (ps: [ ps.cryptography ])' \
      -c python3 tests/fixtures/common/sigstore/generate.py tests/fixtures/common/sigstore

A test certificate authority, transparency log and certificate transparency
log stand in for Fulcio, Rekor and the CT log of the public Sigstore instance;
trusted_root.json names the three. The bundles carry what the real ones
carry: a short-lived certificate with the workflow identity as its URI SAN,
the OIDC issuer extension and an embedded SCT, and a transparency log entry
with its signed entry timestamp (and, for the v0.3 attestation, an inclusion
proof with a signed checkpoint). The signing time is fixed, so verification
does not depend on the clock.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import json
import struct
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ISSUER = "https://token.actions.githubusercontent.com"
REPOSITORY = "https://github.com/example/example-release"
FORK = "https://github.com/example/example-fork"
START = datetime.datetime(2026, 1, 1, tzinfo=datetime.UTC)
SIGNED = datetime.datetime(2026, 11, 1, tzinfo=datetime.UTC)
SCT_OID = x509.ObjectIdentifier("1.3.6.1.4.1.11129.2.4.2")
ISSUER_V1_OID = x509.ObjectIdentifier("1.3.6.1.4.1.57264.1.1")
ISSUER_V2_OID = x509.ObjectIdentifier("1.3.6.1.4.1.57264.1.8")
# The signed note format separates a signature line with U+2014.
CHECKPOINT_DASH = chr(0x2014)


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def spki(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def der_length(length: int) -> bytes:
    if length < 0x80:
        return bytes([length])
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(encoded)]) + encoded


def der_utf8(text: str) -> bytes:
    data = text.encode()
    return b"\x0c" + der_length(len(data)) + data


def der_octets(data: bytes) -> bytes:
    return b"\x04" + der_length(len(data)) + data


class Authority:
    def __init__(self, name: str) -> None:
        self.key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name(
            [
                x509.NameAttribute(NameOID.ORGANIZATION_NAME, "example.invalid"),
                x509.NameAttribute(NameOID.COMMON_NAME, name),
            ]
        )
        self.name = subject
        self.cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(self.key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(START)
            .not_valid_after(START + datetime.timedelta(days=36500))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(
                x509.KeyUsage(
                    digital_signature=False,
                    content_commitment=False,
                    key_encipherment=False,
                    data_encipherment=False,
                    key_agreement=False,
                    key_cert_sign=True,
                    crl_sign=True,
                    encipher_only=False,
                    decipher_only=False,
                ),
                critical=True,
            )
            .sign(self.key, hashes.SHA256())
        )

    def der(self) -> bytes:
        return self.cert.public_bytes(serialization.Encoding.DER)


class Log:
    def __init__(self) -> None:
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.log_id = hashlib.sha256(spki(self.key)).digest()
        self.index = 0

    def sign(self, data: bytes) -> bytes:
        return self.key.sign(data, ec.ECDSA(hashes.SHA256()))


def leaf(
    authority: Authority, ct: Log, identity: str, when: datetime.datetime
) -> tuple[ec.EllipticCurvePrivateKey, bytes]:
    """A Fulcio-style certificate for IDENTITY with an embedded SCT of CT."""
    key = ec.generate_private_key(ec.SECP256R1())
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([]))
        .issuer_name(authority.name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(when - datetime.timedelta(minutes=1))
        .not_valid_after(when + datetime.timedelta(minutes=10))
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=False)
        .add_extension(x509.SubjectAlternativeName([x509.UniformResourceIdentifier(identity)]), critical=True)
        .add_extension(x509.UnrecognizedExtension(ISSUER_V1_OID, ISSUER.encode()), critical=False)
        .add_extension(x509.UnrecognizedExtension(ISSUER_V2_OID, der_utf8(ISSUER)), critical=False)
    )
    # The SCT signs the certificate without its SCT list, which is the last
    # extension of the final certificate.
    tbs = builder.sign(authority.key, hashes.SHA256()).tbs_certificate_bytes
    timestamp = int(when.timestamp() * 1000)
    issuer_key_hash = hashlib.sha256(
        authority.cert.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
        )
    ).digest()
    signed = (
        b"\x00\x00"
        + struct.pack(">Q", timestamp)
        + b"\x00\x01"
        + issuer_key_hash
        + len(tbs).to_bytes(3, "big")
        + tbs
        + b"\x00\x00"
    )
    signature = ct.sign(signed)
    sct = (
        b"\x00"
        + ct.log_id
        + struct.pack(">Q", timestamp)
        + b"\x00\x00"
        + b"\x04\x03"
        + struct.pack(">H", len(signature))
        + signature
    )
    sct_list = struct.pack(">H", len(sct) + 2) + struct.pack(">H", len(sct)) + sct
    cert = builder.add_extension(x509.UnrecognizedExtension(SCT_OID, der_octets(sct_list)), critical=False).sign(
        authority.key, hashes.SHA256()
    )
    return key, cert.public_bytes(serialization.Encoding.DER)


def pem(der: bytes) -> bytes:
    return x509.load_der_x509_certificate(der).public_bytes(serialization.Encoding.PEM)


def tlog_entry(rekor: Log, body: dict[str, object], when: datetime.datetime, proof: bool) -> dict[str, object]:
    canonical_body = canonical(body)
    integrated = int(when.timestamp())
    index = rekor.index
    rekor.index += 1
    payload = {
        "body": b64(canonical_body),
        "integratedTime": integrated,
        "logID": rekor.log_id.hex(),
        "logIndex": index,
    }
    entry: dict[str, object] = {
        "logIndex": str(index),
        "logId": {"keyId": b64(rekor.log_id)},
        "kindVersion": {"kind": body["kind"], "version": body["apiVersion"]},
        "integratedTime": str(integrated),
        "inclusionPromise": {"signedEntryTimestamp": b64(rekor.sign(canonical(payload)))},
    }
    if proof:
        # A tree of one leaf: the root is the leaf hash, the proof has no hashes.
        root = hashlib.sha256(b"\x00" + canonical_body).digest()
        origin = "rekor.example.invalid - 1"
        note = f"{origin}\n1\n{b64(root)}\n"
        signature = rekor.log_id[:4] + rekor.sign(note.encode())
        entry["inclusionProof"] = {
            "logIndex": "0",
            "rootHash": b64(root),
            "treeSize": "1",
            "hashes": [],
            "checkpoint": {"envelope": f"{note}\n{CHECKPOINT_DASH} rekor.example.invalid {b64(signature)}\n"},
        }
    entry["canonicalizedBody"] = b64(canonical_body)
    return entry


def message_signature(authority: Authority, ct: Log, rekor: Log, identity: str, blob: bytes, when: datetime.datetime):
    key, cert = leaf(authority, ct, identity, when)
    signature = key.sign(blob, ec.ECDSA(hashes.SHA256()))
    digest = hashlib.sha256(blob).digest()
    body = {
        "apiVersion": "0.0.1",
        "kind": "hashedrekord",
        "spec": {
            "data": {"hash": {"algorithm": "sha256", "value": digest.hex()}},
            "signature": {"content": b64(signature), "publicKey": {"content": b64(pem(cert))}},
        },
    }
    return cert, signature, digest, body


def bundle_v01(
    authority: Authority, ct: Log, rekor: Log, identity: str, blob: bytes, when: datetime.datetime
) -> dict[str, object]:
    cert, signature, digest, body = message_signature(authority, ct, rekor, identity, blob, when)
    return {
        "mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.1",
        "verificationMaterial": {
            "x509CertificateChain": {"certificates": [{"rawBytes": b64(cert)}]},
            "tlogEntries": [tlog_entry(rekor, body, when, proof=False)],
        },
        "messageSignature": {
            "messageDigest": {"algorithm": "SHA2_256", "digest": b64(digest)},
            "signature": b64(signature),
        },
    }


def bundle_legacy(
    authority: Authority, ct: Log, rekor: Log, identity: str, blob: bytes, when: datetime.datetime
) -> dict[str, object]:
    """The format `cosign sign-blob --bundle` wrote before the Sigstore bundle."""
    cert, signature, _digest, body = message_signature(authority, ct, rekor, identity, blob, when)
    entry = tlog_entry(rekor, body, when, proof=False)
    return {
        "base64Signature": b64(signature),
        "cert": b64(pem(cert)),
        "rekorBundle": {
            "SignedEntryTimestamp": entry["inclusionPromise"]["signedEntryTimestamp"],  # type: ignore[index]
            "Payload": {
                "body": entry["canonicalizedBody"],
                "integratedTime": int(str(entry["integratedTime"])),
                "logIndex": int(str(entry["logIndex"])),
                "logID": rekor.log_id.hex(),
            },
        },
    }


def attestation_v03(
    authority: Authority, ct: Log, rekor: Log, identity: str, name: str, blob: bytes, when: datetime.datetime
) -> dict[str, object]:
    """A GitHub-style build provenance attestation: an in-toto statement in DSSE."""
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": name, "digest": {"sha256": hashlib.sha256(blob).hexdigest()}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {"buildType": "https://example.invalid/build/v1"},
            "runDetails": {"builder": {"id": identity}},
        },
    }
    payload = canonical(statement)
    payload_type = "application/vnd.in-toto+json"
    pae = b"DSSEv1 %d %s %d %s" % (len(payload_type), payload_type.encode(), len(payload), payload)
    key, cert = leaf(authority, ct, identity, when)
    signature = key.sign(pae, ec.ECDSA(hashes.SHA256()))
    envelope = {"payload": b64(payload), "payloadType": payload_type, "signatures": [{"sig": b64(signature)}]}
    body = {
        "apiVersion": "0.0.1",
        "kind": "dsse",
        "spec": {
            "envelopeHash": {"algorithm": "sha256", "value": hashlib.sha256(canonical(envelope)).hexdigest()},
            "payloadHash": {"algorithm": "sha256", "value": hashlib.sha256(payload).hexdigest()},
            "signatures": [{"signature": b64(signature), "verifier": b64(pem(cert))}],
        },
    }
    return {
        "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
        "verificationMaterial": {
            "certificate": {"rawBytes": b64(cert)},
            "tlogEntries": [tlog_entry(rekor, body, when, proof=True)],
        },
        "dsseEnvelope": envelope,
    }


def trusted_root(authority: Authority, rekor: Log, ct: Log) -> dict[str, object]:
    def key(log: Log) -> dict[str, object]:
        return {
            "rawBytes": b64(spki(log.key)),
            "keyDetails": "PKIX_ECDSA_P256_SHA_256",
            "validFor": {"start": "2026-01-01T00:00:00Z"},
        }

    return {
        "mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1",
        "tlogs": [
            {
                "baseUrl": "https://rekor.example.invalid",
                "hashAlgorithm": "SHA2_256",
                "publicKey": key(rekor),
                "logId": {"keyId": b64(rekor.log_id)},
            }
        ],
        "certificateAuthorities": [
            {
                "subject": {"organization": "example.invalid", "commonName": "example-fulcio"},
                "uri": "https://fulcio.example.invalid",
                "certChain": {"certificates": [{"rawBytes": b64(authority.der())}]},
                "validFor": {"start": "2026-01-01T00:00:00Z"},
            }
        ],
        "ctlogs": [
            {
                "baseUrl": "https://ctfe.example.invalid",
                "hashAlgorithm": "SHA2_256",
                "publicKey": key(ct),
                "logId": {"keyId": b64(ct.log_id)},
            }
        ],
        "timestampAuthorities": [],
    }


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="ascii")


def main() -> None:
    out = Path(sys.argv[1])
    authority, foreign = Authority("example-fulcio"), Authority("example-foreign")
    rekor, ct = Log(), Log()
    blobs = {}
    for version in ("4.1.0", "5.0.0"):
        # No shebang: the file stays data in the tree (a fixture with a shebang must be
        # executable, and the Nix build sandbox would rewrite it), and an executable
        # copy still runs, through the shell's fallback for files without one.
        blob = f"printf 'example-release %s\\n' {version}\n".encode()
        (out / f"example-release-{version}").write_bytes(blob)
        blobs[version] = blob

    def workflow(repository: str, version: str) -> str:
        return f"{repository}/.github/workflows/release.yml@refs/tags/v{version}"

    minute = datetime.timedelta(minutes=1)
    write_json(out / "trusted_root.json", trusted_root(authority, rekor, ct))
    write_json(
        out / "example-release-4.1.0.sigstore.json",
        bundle_v01(authority, ct, rekor, workflow(REPOSITORY, "4.1.0"), blobs["4.1.0"], SIGNED),
    )
    write_json(
        out / "example-release-4.1.0.foreign.sigstore.json",
        bundle_v01(foreign, ct, rekor, workflow(REPOSITORY, "4.1.0"), blobs["4.1.0"], SIGNED + minute),
    )
    write_json(
        out / "example-release-5.0.0.sigstore",
        bundle_legacy(authority, ct, rekor, workflow(REPOSITORY, "5.0.0"), blobs["5.0.0"], SIGNED + 2 * minute),
    )
    write_json(
        out / "example-release-5.0.0.fork.sigstore.json",
        bundle_v01(authority, ct, rekor, workflow(FORK, "5.0.0"), blobs["5.0.0"], SIGNED + 3 * minute),
    )
    attestation = attestation_v03(
        authority,
        ct,
        rekor,
        workflow(REPOSITORY, "5.0.0"),
        "example-release-linux-x64",
        blobs["5.0.0"],
        SIGNED + 4 * minute,
    )
    (out / "example-release-5.0.0.intoto.jsonl").write_text(json.dumps(attestation) + "\n", encoding="ascii")
    deb = (out.parent / "debs" / "example-term_0.9.0_amd64.deb").read_bytes()
    write_json(
        out / "example-term_0.9.0_amd64.deb.sigstore.json",
        bundle_v01(
            authority,
            ct,
            rekor,
            workflow("https://github.com/example-org/example-term", "0.9.0"),
            deb,
            SIGNED + 5 * minute,
        ),
    )


if __name__ == "__main__":
    main()
