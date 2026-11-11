"""Upstream access of ``pins latest``: HTTP (urllib), the GitHub CLI and
``git ls-remote``.

GitHub repositories are named ``owner/name``; their git URL is
``https://github.com/owner/name`` (tests redirect it with git's
``url.<base>.insteadOf``). HEAD requests stay HEAD across redirects, so a
size is read without downloading the file. Failures raise: a failed
command is a RuntimeError with its standard error, HTTP failures are
urllib's errors, and ``UpstreamError`` marks an answer whose format is not
the expected one (the runner turns it into an error row of the affected
ids).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
from dataclasses import dataclass
from email.message import Message
from http.client import HTTPMessage
from typing import IO, Any

from dotsteward_cli import versions

from .model import STABLE_TAG

HTTP_TIMEOUT = 20
COMMAND_TIMEOUT = 60
# The release list of a repository is read in pages of its newest releases, at most this many. A
# page of 100 releases of a repository with many assets each times out at GitHub (HTTP 504).
RELEASES_PAGE = 30
RELEASES_PAGES = 10
# A first number this high is a year: a calendar version.
CALENDAR_YEAR = 1900
USER_AGENT = "dotsteward-pins/1.0"
GITHUB = "https://github.com"
_GITHUB_REFERENCE = re.compile(r"github:(?P<owner>[^/]+)/(?P<repo>[^/?#]+)(?:[/?#].*)?")
_HEX40 = re.compile(r"[0-9a-f]{40}")
_GITHUB_URL = re.compile(
    r"(?:https://|git\+https://|ssh://git@|git@)github\.com[/:](?P<owner>[^/]+)/(?P<repo>[^/?#]+?)(?:\.git)?/?(?:[?#].*)?"
)


class UpstreamError(Exception):
    """An upstream answer this adapter cannot use (a format change)."""


def github_url(repo: str) -> str:
    return f"{GITHUB}/{repo}"


def github_repo(text: Any) -> str | None:
    """``owner/name`` of a ``github:`` reference or a GitHub URL, else None."""
    if not isinstance(text, str):
        return None
    match = _GITHUB_REFERENCE.fullmatch(text) or _GITHUB_URL.fullmatch(text)
    if match is None:
        return None
    return f"{match['owner']}/{match['repo']}"


def tag_version(tag: str, prefix: str = "") -> str:
    """The version a release tag names."""
    return tag[len(prefix) :] if prefix else tag.lstrip("v")


def _calendar(version: str) -> bool:
    first = re.match(r"[0-9]+", version)
    return first is not None and int(first[0]) >= CALENDAR_YEAR


def same_family(version: str, like: str | None) -> bool:
    """VERSION belongs to the family of LIKE (any, without LIKE): plain versions (1.4.0) and
    calendar versions (2024.11.01) are two, which tags without a prefix cannot tell apart."""
    return like is None or _calendar(version) == _calendar(str(like).lstrip("v"))


def is_stable_tag(tag: Any, prefix: str = "") -> bool:
    if not isinstance(tag, str) or not tag.startswith(prefix):
        return False
    rest = tag[len(prefix) :]
    return STABLE_TAG.fullmatch(rest) is not None and (not prefix or rest[:1].isdigit())


@dataclass(frozen=True)
class Head:
    """The answer of a HEAD request: the final URL and the headers."""

    url: str
    headers: Message

    @property
    def size(self) -> int | None:
        length = self.headers.get("Content-Length")
        return int(length) if length and length.isdigit() else None

    @property
    def file_name(self) -> str:
        """The Content-Disposition file name, else the last URL segment."""
        name = self.headers.get_filename()
        if name:
            return os.path.basename(name)
        path = urllib.parse.urlsplit(self.url).path
        return urllib.parse.unquote(path.rsplit("/", 1)[-1])


class _KeepHeadRedirect(urllib.request.HTTPRedirectHandler):
    """Follows redirects of HEAD requests with HEAD (urllib uses GET)."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: IO[bytes],
        code: int,
        msg: str,
        headers: HTTPMessage,
        newurl: str,
    ) -> urllib.request.Request | None:
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and req.get_method() == "HEAD":
            new.method = "HEAD"
        return new


class Upstream:
    """The network side of ``pins latest`` (shared by the worker threads)."""

    def __init__(self) -> None:
        self._opener = urllib.request.build_opener(_KeepHeadRedirect())

    # -- HTTP --

    def http_get(self, url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with self._opener.open(request, timeout=HTTP_TIMEOUT) as response:
            body: bytes = response.read()
        return body

    def http_text(self, url: str) -> str:
        return self.http_get(url).decode("utf-8", "replace")

    def http_json(self, url: str) -> Any:
        try:
            return json.loads(self.http_get(url))
        except ValueError as error:
            raise UpstreamError(f"{url} is not JSON ({error})") from error

    def http_head(self, url: str) -> Head:
        request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        with self._opener.open(request, timeout=HTTP_TIMEOUT) as response:
            return Head(response.geturl(), response.headers)

    # -- commands --

    def run_text(self, command: list[str]) -> str:
        environment = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1"}
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=COMMAND_TIMEOUT,
                env=environment,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"{' '.join(command[:2])} timed out after {COMMAND_TIMEOUT} seconds") from error
        if result.returncode != 0:
            lines = [text.strip() for text in result.stderr.splitlines() if text.strip()]
            detail = "; ".join(lines) or f"exit status {result.returncode}"
            raise RuntimeError(f"{' '.join(command[:2])} failed: {detail}")
        return result.stdout

    def gh_json(self, path: str) -> Any:
        """``gh api PATH`` as JSON (RuntimeError, ValueError or OSError on
        failure)."""
        return json.loads(self.run_text(["gh", "api", path]))

    def tree_sha(self, repo: str, revision: str, path: str) -> str | None:
        """The tree object of the directory PATH ("" for the root) at the
        commit REVISION of a GitHub repository (``gh api
        repos/<repo>/git/trees/<revision>:<path>``), or None when the
        revision has no directory there (HTTP 404, or 422 for a file)."""
        try:
            data = self.gh_json(f"repos/{repo}/git/trees/{revision}:{urllib.parse.quote(path)}")
        except RuntimeError as error:
            if "(HTTP 404)" in str(error) or "(HTTP 422)" in str(error):
                return None
            raise
        sha = data.get("sha") if isinstance(data, dict) else None
        if not isinstance(sha, str) or not _HEX40.fullmatch(sha):
            raise UpstreamError(f"the tree of {repo} {revision[:12]}:{path or '.'} has no tree object id")
        return sha

    # -- git --

    def remote_refs(self, url: str, *patterns: str) -> dict[str, str]:
        """``git ls-remote URL PATTERN...`` as {ref: object}."""
        refs = {}
        for text in self.run_text(["git", "ls-remote", url, *patterns]).splitlines():
            sha, _, ref = text.partition("\t")
            if ref:
                refs[ref] = sha
        return refs

    def remote_heads(self, url: str, pattern: str) -> dict[str, str]:
        """Branches (by short name) and HEAD matching a ls-remote pattern."""
        heads = {}
        for ref, sha in self.remote_refs(url, pattern).items():
            heads[ref.removeprefix("refs/heads/")] = sha
        return heads

    def stable_tags(self, url: str, prefix: str = "") -> list[str]:
        tags = []
        for text in self.run_text(["git", "ls-remote", "--tags", "--refs", url]).splitlines():
            _, _, ref = text.partition("\t")
            name = ref.removeprefix("refs/tags/")
            if is_stable_tag(name, prefix):
                tags.append(name)
        return tags

    def newest_tag(
        self, url: str, prefix: str = "", *, excluded: frozenset[str] = frozenset(), like: str | None = None
    ) -> str | None:
        tags = [
            tag
            for tag in self.stable_tags(url, prefix)
            if tag not in excluded and (prefix or same_family(tag_version(tag), like))
        ]
        best = versions.newest(tag_version(tag, prefix) for tag in tags)
        if best is None:
            return None
        return next(tag for tag in tags if tag_version(tag, prefix) == best)

    def release_of(self, repo: str, tag: str) -> dict[str, Any] | None:
        """The GitHub release of TAG, None when gh fails or GitHub has none."""
        try:
            release = self.gh_json(f"repos/{repo}/releases/tags/{tag}")
        except (RuntimeError, ValueError, OSError):
            return None
        return release if isinstance(release, dict) else None

    def latest_release(
        self, repo: str, prefix: str = "", *, like: str | None = None
    ) -> tuple[str | None, dict[str, Any] | None]:
        """The newest stable release of a GitHub repository in the tag family of PREFIX, and its
        release JSON: of the release list (``gh api repos/<repo>/releases?per_page=30&page=N``, the
        newest releases first, read page by page until a page holds a stable release of the family,
        at most RELEASES_PAGES pages), the highest version whose tag is a stable tag with the prefix
        and that is neither a draft nor a prerelease, whatever GitHub calls latest. Only the list
        says which tag is a draft or a prerelease: a list that cannot be read, or that holds no
        stable release of the family in the pages read, is an UpstreamError. When the whole list
        holds none, the newest stable tag from ``git ls-remote`` that the list did not flag, without
        a release. Without a prefix, LIKE (the pinned version) keeps the family: plain and calendar
        versions are two."""
        flagged: set[str] = set()
        stable: dict[str, dict[str, Any]] = {}
        for number in range(1, RELEASES_PAGES + 1):
            path = f"repos/{repo}/releases?per_page={RELEASES_PAGE}&page={number}"
            try:
                listed = self.gh_json(path)
            except (RuntimeError, ValueError, OSError) as error:
                raise UpstreamError(f"the release list of {repo} could not be read ({error})") from error
            if not isinstance(listed, list):
                raise UpstreamError(f"the release list of {repo} is no list")
            for release in listed:
                tag = release.get("tag_name") if isinstance(release, dict) else None
                if not isinstance(tag, str) or not is_stable_tag(tag, prefix):
                    continue
                if not prefix and not same_family(tag_version(tag), like):
                    continue
                if release.get("draft") or release.get("prerelease"):
                    flagged.add(tag)
                else:
                    stable.setdefault(tag_version(tag, prefix), release)
            best = versions.newest(stable)
            if best is not None:
                return stable[best]["tag_name"], stable[best]
            if len(listed) < RELEASES_PAGE:
                return self.newest_tag(github_url(repo), prefix, excluded=frozenset(flagged), like=like), None
        family = prefix or "of plain version tags"
        raise UpstreamError(
            f"{repo}: no stable release of the family {family} in the {RELEASES_PAGE * RELEASES_PAGES} newest releases"
        )
