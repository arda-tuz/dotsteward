"""``git-compare``: changes of watched paths in a GitHub repository since a
pinned commit.

Fields:

    repo           owner/name (a lock template); or
    repo_at        lock path of a GitHub URL or ``github:`` reference
    revision_at    lock path of the pinned commit (required; 40 hex digits)
    watched        regular expressions (full match) of the paths that
                   matter (required)
    release_bound  true: compare with the newest release tag instead of
                   the default branch, so unreleased changes do not count

Query: the head (``git ls-remote``: HEAD, or the release tag from ``gh``
with the stable-tag fallback, peeled), then one ``gh api
repos/<repo>/compare/<revision>...<head>`` unless nothing moved. Rows with
the same repository, revision and release binding share that compare
(vendored skills included). Status ``review`` when a watched path changed
or the file list may be truncated (300 files), else ``current``. Current
and latest are 12-character commits; details: ``head``, ``release``,
``ahead_by``, ``changed_paths`` (40 at most), ``files_truncated``.

Example::

    { "id": "example_tool", "adapter": "git-compare", "at": "example_tool",
      "repo_at": ".source", "revision_at": ".inspected_revision",
      "watched": ["README\\\\.md", "bin/[^/]+\\\\.sh"] }
"""

from __future__ import annotations

from collections.abc import Callable, Hashable
from typing import Any, ClassVar

from ...checker import HEX40
from ...lockfile import Scope, parse_path, scalar_text
from ...rules import boolean
from ..model import Row, item
from ..upstream import Upstream, UpstreamError, github_repo, github_url
from . import Adapter, FieldSpec, PlanContext, PlanError, Request, regexes, repository

FILES_LIMIT = 300
CHANGED_LIMIT = 40


def compare_rows(requests: list[Request], upstream: Upstream) -> list[Row]:
    """One compare for requests sharing (repo, revision, release_bound);
    each request's ``matches`` decides its changed paths."""
    first = requests[0].values
    repo, revision, release_bound = first["repo"], first["revision"], first["release_bound"]
    release = None
    if release_bound:
        release, _ = upstream.latest_release(repo)
        if release is None:
            raise UpstreamError(f"{repo} has no stable release or tag")
        refs = upstream.remote_refs(github_url(repo), f"refs/tags/{release}", f"refs/tags/{release}^{{}}")
        head = refs.get(f"refs/tags/{release}^{{}}") or refs.get(f"refs/tags/{release}")
    else:
        head = upstream.remote_heads(github_url(repo), "HEAD").get("HEAD")
    if head is None:
        raise RuntimeError(f"{repo} {release or 'HEAD'} cannot be read")
    if head == revision:
        data: dict[str, Any] = {"files": [], "ahead_by": 0}
    else:
        data = upstream.gh_json(f"repos/{repo}/compare/{revision}...{head}")
        if not isinstance(data, dict) or not isinstance(data.get("files"), list):
            raise UpstreamError(f"the compare of {repo} has no file list")
        if not all(isinstance(entry, dict) and isinstance(entry.get("filename"), str) for entry in data["files"]):
            raise UpstreamError(f"the compare of {repo} lists a file without a name")
    files = [entry["filename"] for entry in data["files"]]
    truncated = len(files) >= FILES_LIMIT
    rows = []
    for request in requests:
        matches: Callable[[str], bool] = request.values["matches"]
        changed = sorted(name for name in files if matches(name))
        status = "review" if changed or truncated else "current"
        rows.append(
            item(
                request.id,
                request.kind,
                revision[:12],
                head[:12],
                status,
                request.adapter.source_of(request),
                head=head,
                release=release,
                ahead_by=data.get("ahead_by"),
                changed_paths=changed[:CHANGED_LIMIT],
                files_truncated=truncated,
                note=request.note,
            )
        )
    return rows


class CompareAdapter(Adapter):
    """Shared grouping of the compare based adapters."""

    VERSIONED = False

    def default_source(self, request: Request) -> str:
        return github_url(request.values["repo"])

    def group_key(self, request: Request) -> Hashable | None:
        values = request.values
        return ("compare", values["repo"], values["revision"], values["release_bound"])

    def fetch_group(self, requests: list[Request], upstream: Upstream) -> list[Row]:
        return compare_rows(requests, upstream)


class GitCompare(CompareAdapter):
    name = "git-compare"
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "repo": FieldSpec(repository),
        "repo_at": FieldSpec(parse_path),
        "revision_at": FieldSpec(parse_path, required=True),
        "watched": FieldSpec(regexes, required=True),
        "release_bound": FieldSpec(boolean, default=False),
    }

    def validate(self) -> list[str]:
        return self.one_of("repo", "repo_at")

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        locks = ctx.locks
        if self.values["repo"] is not None:
            repo = locks.render(self.values["repo"], scope)
        else:
            source = self.lock_value(locks, self.values["repo_at"], scope)
            repo = github_repo(source)
            if repo is None:
                raise PlanError(f"{source!r} is not a GitHub repository")
        revision = scalar_text(self.lock_value(locks, self.values["revision_at"], scope))
        if not HEX40.fullmatch(revision):
            raise PlanError(f"the pinned revision {revision!r} is not a 40-digit commit")
        watched = self.values["watched"]
        request.current = revision[:12]
        request.values.update(
            repo=repo,
            revision=revision,
            release_bound=self.values["release_bound"],
            matches=lambda name: any(pattern.fullmatch(name) for pattern in watched),
        )
