"""One writer per group kind. A writer works on the files; the runner keeps their
bytes and restores them when it raises."""

from __future__ import annotations

import datetime
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from dotsteward_cli import atomic

from ..instance import Instance
from ..latest.adapters import Request
from ..latest.upstream import github_repo
from ..lockfile import VERSIONS, LockPath, Locks, dump, parse_path
from ..syncer import sync_locks, write_changed
from . import plan as routing
from .authenticity import Authenticity, Finding, Release
from .plan import Declared, Group, Move, flake_original, hash_fields, pin_of, version_field
from .tools import PLACEHOLDER, GroupFailure, Tools, Waits, nix_system

TEMPLATE_FILES = ("bootstrap.sh", ".dotsteward/cli.sh")
# The attribute of a package that builds one fixed-output hash, by the start of the
# field's name. Another field needs the whole package; the sources come first since
# the other fetchers build on them.
HASH_ATTRIBUTES = (("source", "src"), ("cargo", "cargoDeps"), ("vendor", "goModules"), ("npm", "npmDeps"))
REVISION_FIELDS = ("tag_revision", "source_revision")


@dataclass
class Writer:
    instance: Instance
    tools: Tools
    declared: Declared
    # Signatures of the downloads (None: nothing is downloaded, as in the tests of other kinds).
    authenticity: Authenticity | None = None
    # Review items that wait for nothing: what the report should say about a move that happened.
    notes: list[dict[str, Any]] = field(default_factory=list)
    # The authenticity of each moved row, by id: a download's signature, "unsigned" for the rest.
    findings: dict[str, Finding] = field(default_factory=dict)

    # -- locks --

    def edit(self, change: Any) -> None:
        """Runs CHANGE on the lock documents and writes those that changed."""
        locks = self.instance.load_locks()
        before = {kind: dump(document) for kind, document in locks.documents.items()}
        change(locks)
        write_changed(self.instance, locks, before)

    def sync(self, *skills: str) -> None:
        sync_locks(self.instance, False, list(skills))

    # -- what every pin with a release has --

    def release_fields(self, pin: dict[str, Any], tag: str, old_tag: str | None, repository: str | None) -> None:
        """Fills the fields a release decides: its tag, the commit of the tag, the tag
        object and a source URL that names the tag. A field that cannot be filled
        fails the group: no pin is left half-written."""
        if "official_tag" in pin:
            pin["official_tag"] = tag
        source = pin.get("source")
        if old_tag and isinstance(source, str) and source.endswith(f"/tag/{old_tag}"):
            pin["source"] = source[: -len(old_tag)] + tag
        needed = [name for name in (*REVISION_FIELDS, "tag_object") if name in pin]
        if not needed:
            return
        repository = repository or github_repo(pin.get("source")) or github_repo(pin.get("reference"))
        objects = self.tools.tag_objects(repository, tag) if repository else None
        if objects is None:
            raise GroupFailure(f"cannot fill {', '.join(needed)}: no tag {tag} in {repository or 'a known repository'}")
        commit, tag_object = objects
        for name in REVISION_FIELDS:
            if name in pin:
                pin[name] = commit
        if "tag_object" in pin:
            if tag_object is None:
                del pin["tag_object"]
            else:
                pin["tag_object"] = tag_object

    def refresh_hashes(self, path: LockPath, package: str, fields: list[str] | None = None) -> None:
        """Every ``*_nix_sha256`` of the pin at PATH, one fake-hash build each."""
        locks = self.instance.load_locks()
        names = fields if fields is not None else hash_fields(locks.get(path))
        order = {start: index for index, (start, _) in enumerate(HASH_ATTRIBUTES)}

        def rank(name: str) -> int:
            return next((order[start] for start in order if name.startswith(start)), len(order))

        for name in sorted(names, key=rank):
            self.refresh_hash(path.child(name), package)

    def refresh_hash(self, path: LockPath, package: str) -> None:
        name = str(path.steps[-1].key)
        attribute = next((value for start, value in HASH_ATTRIBUTES if name.startswith(start)), None)
        target = f"packages.{nix_system()}.{package}" + (f".{attribute}" if attribute else "")
        self.edit(lambda locks: locks.set(path, PLACEHOLDER))
        got = self.tools.fake_hash_build(target)
        self.edit(lambda locks: locks.set(path, got))

    # -- flake inputs --

    def replace_reference(self, old: str, new: str) -> None:
        path = self.instance.path("flake.nix")
        text = path.read_text(encoding="utf-8")
        count = text.count(f'"{old}"')
        if count != 1:
            raise GroupFailure(f"flake.nix holds the reference {old!r} {count} times, not once")
        atomic.atomic_write(path, text.replace(f'"{old}"', f'"{new}"'))

    def flake_inputs(self, group: Group) -> None:
        locks = self.instance.load_locks()
        for move in group.moves:
            pin = locks.get(_path(move))
            reference = pin["reference"]
            if "channel" in pin:
                head = move.details.get("head")
                if not isinstance(head, str) or pin["revision"] not in reference:
                    raise GroupFailure(f"{move.id}: no head to move to, or {reference!r} does not name the revision")
                self.replace_reference(reference, reference.replace(pin["revision"], head))
            else:
                self.replace_reference(reference, f"{reference.rsplit('/', 1)[0]}/{_tag(move)}")
        self.tools.flake_lock()
        self.sync()
        for move in group.moves:
            self.after_input(move)

    def after_input(self, move: Move) -> None:
        path = _path(move)
        tag = move.details.get("tag")
        if isinstance(tag, str):
            self.fill_release(path, tag, None, None)
        for dependent in self.declared.dependents(path):
            current = self.instance.load_locks()
            pin = pin_of(current, dependent)
            if not isinstance(pin, dict):
                continue
            if isinstance(tag, str):
                self.fill_release(
                    dependent, tag, pin.get("official_tag"), github_repo(current.get(path).get("reference"))
                )
                self.sync()
            if hash_fields(pin):
                self.refresh_hashes(dependent, str(dependent.steps[-1].key))

    def fill_release(self, path: LockPath, tag: str, old_tag: str | None, repository: str | None) -> None:
        self.edit(lambda locks: self.release_fields(locks.get(path), tag, old_tag, repository))

    # -- the framework --

    def framework(self, group: Group) -> None:
        move = group.moves[0]
        tag = str(move.details.get("tag") or move.latest)
        original = flake_original(self.instance)
        text = self.instance.path("flake.nix").read_text(encoding="utf-8")
        strings = set(re.findall(r'"([^"\n]+)"', text))
        if original.get("type") == "github":
            start = f"github:{original['owner']}/{original['repo']}/"
            found = [value for value in strings if value.startswith(start)]
            new = f"{start}{tag}"
        else:
            found = [value for value in strings if value.startswith("git+") and str(original.get("url")) in value]
            new = f"{found[0].split('?', 1)[0]}?ref=refs/tags/{tag}" if len(found) == 1 else ""
        if len(found) != 1:
            raise GroupFailure(f"flake.nix holds {len(found)} references of the framework, not one")
        self.replace_reference(found[0], new)
        self.tools.flake_lock()
        source = self.tools.framework_source()
        for name in TEMPLATE_FILES:
            if not (source / "template" / name).is_file():
                raise GroupFailure(f"the template of {tag} has no {name}")
        for name in TEMPLATE_FILES:
            content = (source / "template" / name).read_bytes()
            atomic.atomic_write(self.instance.path(name), content, mode=0o755, parents=True)
        self.tools.generate()

    # -- plain pins: a download, a package built from source --

    def download(self, group: Group) -> None:
        for move in group.moves:
            self.download_one(move)
        self.sync()

    def download_one(self, move: Move) -> None:
        path = _path(move)
        rule = self.declared.downloads[path.text()]
        fields = {name: rule.values[f"{name}_field"] for name in ("version", "url", "size", "sha256")}
        pin = self.instance.load_locks().get(path)
        old = str(pin[fields["version"]])
        asset = routing.asset_of(move)
        url, size, digest = asset.get("url"), asset.get("size"), asset.get("sha256")
        if not url:
            current = str(pin[fields["url"]])
            if old not in current:
                raise GroupFailure(f"{move.id}: the URL {current!r} does not name the version {old}")
            url, size, digest = current.replace(old, move.latest), None, None
        if not digest or not size:
            fetched, fetched_size = self.tools.prefetch(str(url))
            digest, size = digest or fetched, size or fetched_size
        pin_text = path.text().removeprefix("versions:")
        members, bridge = self._installs(pin_text, move.latest)
        finding = Finding("unsigned")
        if self.authenticity is not None:
            versions_document = self.instance.load_locks().documents[VERSIONS]
            tag = move.details.get("tag")
            release = Release(
                pin=pin_text,
                url=str(url),
                digest=str(digest),
                version=move.latest,
                tag=tag if isinstance(tag, str) and tag else None,
                repository=_repository(move.request) or github_repo(pin.get("source")),
                members=members,
            )
            finding = self.authenticity.examine(versions_document, release)
        finding.bridge = bridge
        self.findings[move.id] = finding

        def change(locks: Locks) -> None:
            target = locks.get(path)
            target[fields["version"]] = move.latest
            target[fields["url"]], target[fields["size"]], target[fields["sha256"]] = url, size, digest
            self.release_fields(target, _tag(move), f"v{old}", _repository(move.request))
            # A signature belongs to one file: the old one never stays with the new file.
            target.pop("signature", None)
            if finding.signature is not None:
                target["signature"] = finding.signature
            record_trust(locks.documents[VERSIONS], pin_text, finding)

        self.edit(change)

    def _installs(self, pin: str, version: str) -> tuple[tuple[str, ...], str | None]:
        """What the components install from PIN, as their manifest mirrors declare it: the
        archive members (install.member, {version} filled in, and those of companions),
        and the repository whose later releases the local APT bridge serves, if any."""
        members: list[str] = []
        bridge: str | None = None
        for system in self.instance.systems:
            for component in self.instance.manifest(system).get("components") or []:
                install = component.get("install") if isinstance(component, dict) else None
                if not isinstance(install, dict):
                    continue
                entries = [install, *[c for c in install.get("companions") or [] if isinstance(c, dict)]]
                for entry in entries:
                    member = entry.get("member")
                    if entry.get("pin") == pin and isinstance(member, str) and member:
                        members.append(member.replace("{version}", version))
                release = install.get("githubRelease")
                if (
                    install.get("pin") == pin
                    and isinstance(release, dict)
                    and isinstance(release.get("repository"), str)
                ):
                    bridge = release["repository"]
        return tuple(dict.fromkeys(members)), bridge

    def nix_package(self, group: Group) -> None:
        for move in group.moves:
            self.nix_package_one(move)
        self.sync()

    def nix_package_one(self, move: Move) -> None:
        path = _path(move)
        name = version_field(move, self.declared, self.instance.load_locks().get(path))
        if name is None:
            raise GroupFailure(f"{move.id}: the pin has no version field")
        field = name

        def change(locks: Locks) -> None:
            target = locks.get(path)
            old = target[field]
            target[field] = move.latest
            if "integrity" in target and move.details.get("integrity"):
                target["integrity"] = move.details["integrity"]
            self.release_fields(target, _tag(move), f"v{old}", _repository(move.request))

        self.edit(change)
        self.sync()
        self.refresh_hashes(path, str(path.steps[-1].key))
        self.findings[move.id] = Finding("unsigned")

    # -- npm bundles --

    def _audit_findings(self, prefix: tuple[str, ...]) -> int | None:
        """How many findings the audit of a lock has; None when it does not say. It exits non-zero
        for a finding, so only its document counts."""
        answer = self.tools.nix_tool_result("nodejs", *prefix, "audit", "--json")
        try:
            return int(json.loads(answer.stdout)["metadata"]["vulnerabilities"]["total"])
        except (ValueError, KeyError, TypeError):
            return None

    def npm(self, group: Group) -> None:
        directory = self.instance.path(group.key)
        before = self._audit_findings(("npm", "--prefix", str(directory)))
        package_path = directory / "package.json"
        package = json.loads(package_path.read_text(encoding="utf-8"))
        locks = self.instance.load_locks()
        rule = None
        for move in group.moves:
            bundle = self.declared.bundles[_path(move).text()]
            rule = bundle.rule
            if bundle.override:
                self._override(package, bundle.dependency, locks.get(_path(move)), move.latest)
            else:
                package["dependencies"][bundle.dependency] = move.latest
        atomic.atomic_write(package_path, json.dumps(package, indent=2, ensure_ascii=False) + "\n")
        prefix = ("npm", "--prefix", str(directory))
        self.tools.nix_tool(
            "nodejs", *prefix, "install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund"
        )
        after = self._audit_findings(prefix)
        # A bundle moves when its findings do not grow: holding a move back would keep them forever,
        # even when the move removes some. More of them, or an audit that says nothing, is a decision.
        if after is None or (after > 0 and (before is None or after > before)):
            raise Waits("npm-audit", reason=f"{after} findings, {before} before" if after is not None else "no answer")
        if after > 0:
            ids = [move.id for move in group.moves]
            self.notes.append({"code": "npm-audit-remaining", "pending": False, "ids": ids, "findings": after})
        self.sync()
        for move in group.moves:
            self._mirror_revision(move)
        self.sync()
        assert rule is not None
        if rule.values["nix_hash_at"] is not None:
            at = self.instance.load_locks().resolve(rule.values["nix_hash_at"])
            self.refresh_hash(at, Path(group.key).name)

    @staticmethod
    def _override(package: dict[str, Any], name: str, pin: dict[str, Any], version: str) -> None:
        overrides = package.setdefault("overrides", {})
        scope = pin.get("override_scope")
        if scope:
            overrides.setdefault(scope, {})[name] = version
        else:
            overrides[name] = version

    def _mirror_revision(self, move: Move) -> None:
        """The revision fields of the pin that mirrors a bundle's dependency: those the
        registry row names, else the commit of the tag of that version."""
        bundle = self.declared.bundles[_path(move).text()]
        at = _path(move)
        if not bundle.override:
            mirrored = next((at for dep, at, _ in bundle.rule.values["mirrors"] if dep == bundle.dependency), None)
            if mirrored is None:
                return
            at = self.instance.load_locks().resolve(mirrored)
        head = move.details.get("git_head")

        def change(locks: Locks) -> None:
            pin = locks.get(at)
            for name in REVISION_FIELDS:
                if name in pin and isinstance(head, str):
                    pin[name] = head
            if not isinstance(head, str):
                self.release_fields(pin, _tag(move), None, None)

        self.edit(change)

    # -- hash-pinned requirements --

    def pypi(self, group: Group) -> None:
        file = self.instance.path(group.key)
        source = file.with_suffix(".in")
        if source.is_file():
            requirements = source.read_text(encoding="utf-8")
        else:
            requirements = "".join(f"{_package(move)}=={move.latest}\n" for move in group.moves)
        regenerate = self.declared.regenerators[group.key]
        text = self.tools.nix_tool(regenerate["package"], *regenerate["command"], stdin=requirements)
        if not text.strip():
            raise GroupFailure(f"{regenerate['command'][0]} wrote no requirements for {group.key}")
        atomic.atomic_write(file, text)

        def change(locks: Locks) -> None:
            for move in group.moves:
                self._pypi_pin(locks, move, text)

        self.edit(change)
        self.sync()
        # PEP 740 attestations are not read yet: a requirement is hash-pinned only.
        self.findings.update((move.id, Finding("unsigned")) for move in group.moves)

    def _pypi_pin(self, locks: Locks, move: Move, text: str) -> None:
        name = _package(move)
        pattern = "[-_.]+".join(re.escape(part) for part in re.split(r"[-_.]+", name))
        found = re.search(rf"^{pattern}==([^\s;\\]+)", text, re.MULTILINE | re.IGNORECASE)
        if found is None:
            raise GroupFailure(f"{move.id}: the regenerated requirements do not pin {name}")
        path = _path(move)
        pin = locks.get(path)
        if isinstance(pin, dict):
            pin[version_field(move, self.declared, pin) or "version"] = found[1]
        else:
            locks.set(path, found[1])


def record_trust(versions: dict[str, Any], pin: str, finding: Finding) -> None:
    """Writes the signer of PIN (and the trusted root a signature was verified
    with) into the ``trust`` section of the versions lock."""
    if finding.signer is None:
        return
    trust = versions.setdefault("trust", {})
    if finding.root is not None:
        trust["sigstore_root"] = finding.root
    trust.setdefault("signers", {})[pin] = finding.signer
    if finding.bridge is not None:
        bridges = trust.setdefault("apt_bridge", {})
        recorded = bridges.get(pin) if isinstance(bridges.get(pin), dict) else {}
        bridges[pin] = {
            "kind": "unsigned",
            "repository": finding.bridge,
            "first_seen": recorded.get("first_seen") or _today(),
        }


def _today() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")


def _path(move: Move) -> LockPath:
    if move.path is None:
        raise GroupFailure(f"{move.id}: the declaration names no pin")
    return parse_path(move.path.text())


def _tag(move: Move) -> str:
    return str(move.details.get("tag") or f"v{move.latest}")


def _repository(request: Request | None) -> str | None:
    value = request.values.get("repo") if request is not None else None
    return value if isinstance(value, str) else None


def _package(move: Move) -> str:
    """The distribution of a pypi row: its adapter's package, else the row id's end."""
    request = move.request
    value = request.values.get("package") if request is not None else None
    return value if isinstance(value, str) and value else move.id.rsplit(".", 1)[-1]
