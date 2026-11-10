"""Replaces a vendored third-party skill with its upstream directory at the head of
its row. It does so only when the vendored copy is exactly what upstream had at the
pinned revision, so that nothing local is lost, and when the scan of the new
directory is clean (N8). Any other case is a review item and writes nothing. A license
kept beside the skill (``agent/skill-licenses/<directory>``, for an upstream that keeps it
above the skill directory) moves with the pin: the nearest ``LICENSE*`` above the
directory at the new revision replaces it."""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from ..digest import directory_sha256
from ..instance import Instance
from ..latest.adapters.skill_source import source_tree_path
from ..latest.upstream import github_repo, github_url
from ..lockfile import Locks
from .plan import Move, skill_entry
from .tools import GroupFailure, Tools, Waits

LICENSES_DIR = "agent/skill-licenses"


class Upstreams:
    """One blobless clone per repository for the run, shared by its skills."""

    def __init__(self, tools: Tools) -> None:
        self.tools = tools
        self.work = tempfile.TemporaryDirectory(prefix="dotsteward-pins-skills-")
        self.clones: dict[str, Path] = {}

    def close(self) -> None:
        self.work.cleanup()

    def clone(self, repository: str) -> Path:
        if repository not in self.clones:
            target = Path(self.work.name) / f"clone-{len(self.clones)}"
            command = ["git", "clone", "--quiet", "--bare", "--filter=blob:none", github_url(repository), str(target)]
            self.tools.checked(command, cwd=Path(self.work.name))
            self.clones[repository] = target
        return self.clones[repository]

    def license_above(self, clone: Path, revision: str, source_path: str) -> tuple[str, bytes] | None:
        """The nearest license file above SOURCE_PATH at REVISION: its name and content."""
        parts = [part for part in source_path.strip("/").split("/") if part]
        for depth in range(len(parts) - 1, -1, -1):
            treeish = f"{revision}:{'/'.join(parts[:depth])}"
            listed = subprocess.run(
                ["git", "-C", str(clone), "ls-tree", "-z", treeish],
                capture_output=True,
                timeout=120,
                check=False,
                stdin=subprocess.DEVNULL,
            )
            if listed.returncode != 0:
                continue
            found = []
            for line in listed.stdout.split(b"\0"):
                meta, _, name = line.partition(b"\t")
                fields = meta.split()
                if len(fields) == 3 and fields[1] == b"blob" and name.lower().startswith(b"license"):
                    found.append((name, fields[2]))
            if found:
                name, blob = sorted(found)[0]
                content = subprocess.run(
                    ["git", "-C", str(clone), "cat-file", "blob", blob.decode()],
                    capture_output=True,
                    timeout=600,
                    check=False,
                    stdin=subprocess.DEVNULL,
                )
                if content.returncode != 0:
                    raise GroupFailure(f"cannot read the license of {treeish}")
                return name.decode(errors="replace"), content.stdout
        return None

    def extract(self, clone: Path, revision: str, source_path: str, target: Path) -> bool:
        """The directory at REVISION into TARGET; False when there is none."""
        treeish = f"{revision}:{source_path}" if source_path else revision
        check = self.tools.run(["git", "-C", str(clone), "cat-file", "-t", treeish], timeout=120)
        if check.returncode != 0 or check.stdout.strip() != "tree":
            return False
        command = ["git", "-C", str(clone), "archive", "--format=tar", treeish]
        result = subprocess.run(command, capture_output=True, timeout=600, check=False, stdin=subprocess.DEVNULL)
        if result.returncode != 0:
            raise GroupFailure(f"git archive {treeish} failed: {result.stderr.decode(errors='replace').strip()}")
        target.mkdir(parents=True)
        with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
            archive.extractall(target, filter="data")
        return True


def replace_skill(instance: Instance, tools: Tools, upstreams: Upstreams, locks: Locks, move: Move) -> list[Path]:
    """Replaces the directory, and the license beside it; returns what changed, the caller
    updates the lock."""
    name = move.id.removeprefix("skills.")
    entry = skill_entry(locks, name)
    head = move.details.get("head")
    if entry is None or not isinstance(head, str):
        raise GroupFailure(f"{move.id}: the row has no head or the skill is not in the lock")
    repository = github_repo(entry.get("source"))
    if repository is None:
        raise GroupFailure(f"{move.id}: the source {entry.get('source')!r} is not a GitHub repository")
    clone = upstreams.clone(repository)
    source_path = source_tree_path(str(entry.get("source_path", "")))
    vendored = instance.path(instance.vendor_dir) / str(entry.get("directory", name))
    beside = instance.path(LICENSES_DIR) / str(entry.get("directory", name))
    license_file = upstreams.license_above(clone, head, source_path) if beside.is_dir() and source_path else None
    with tempfile.TemporaryDirectory(prefix="dotsteward-pins-skill-") as work:
        old, new = Path(work) / "old", Path(work) / "new"
        known = upstreams.extract(clone, str(entry["revision"]), source_path, old)
        if not known or not vendored.is_dir() or directory_sha256(old) != directory_sha256(vendored):
            raise Waits("skill-local-delta", reason="the vendored copy is not upstream at the pinned revision")
        if not upstreams.extract(clone, head, source_path, new):
            raise Waits("skill-source-missing", reason=f"the head has no directory {source_path or '.'}")
        scan = tools.dotsteward("scan", "--tree", "--redact", cwd=new)
        if scan.returncode != 0:
            found = [line.strip() for line in scan.stderr.splitlines() + scan.stdout.splitlines() if line.strip()]
            raise Waits("skill-scan-finding", findings=found[:20])
        shutil.rmtree(vendored)
        shutil.copytree(new, vendored, symlinks=True)
    if license_file is None:
        return [vendored]
    shutil.rmtree(beside)
    beside.mkdir(parents=True)
    (beside / license_file[0]).write_bytes(license_file[1])
    return [vendored, beside]


def relative(instance: Instance, path: Path) -> str:
    return os.path.relpath(path, instance.root)
