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
from typing import Any

from .model import STABLE_TAG, newest

HTTP_TIMEOUT = 20
COMMAND_TIMEOUT = 60
USER_AGENT = "dotsteward-pins/1.0"
GITHUB = "https://github.com"
_GITHUB_REFERENCE = re.compile(r"github:(?P<owner>[^/]+)/(?P<repo>[^/?#]+)(?:[/?#].*)?")
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

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
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
            return response.read()

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

    def newest_tag(self, url: str, prefix: str = "") -> str | None:
        tags = self.stable_tags(url, prefix)
        best = newest(tag_version(tag, prefix) for tag in tags)
        if best is None:
            return None
        return next(tag for tag in tags if tag_version(tag, prefix) == best)

    def latest_release(self, repo: str, prefix: str = "") -> tuple[str | None, dict[str, Any] | None]:
        """The newest release tag of a GitHub repository and its release:
        the GitHub latest release when its tag is a stable tag with the
        prefix, otherwise (gh failing, missing or answering another tag
        family) the newest stable tag from ``git ls-remote``, without a
        release."""
        try:
            release = self.gh_json(f"repos/{repo}/releases/latest")
        except (RuntimeError, ValueError, OSError):
            release = None
        if isinstance(release, dict) and is_stable_tag(release.get("tag_name"), prefix):
            return release["tag_name"], release
        return self.newest_tag(github_url(repo), prefix), None
