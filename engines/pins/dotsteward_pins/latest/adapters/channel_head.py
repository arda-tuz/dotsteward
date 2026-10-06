"""``channel-head``: a pinned commit of a release channel branch (nixpkgs
``nixos-YY.MM``, Home Manager ``release-YY.MM``).

Fields:

    url              git URL of the repository; default the GitHub URL of
                     the pin's ``reference`` (``github:owner/name/...``)
    prefix           branch prefix of the release series; default the
                     channel name without its trailing YY.MM
    channel_field    pin field naming the branch (default "channel")
    revision_field   pin field holding the pinned commit (default
                     "revision")

Query: ``git ls-remote <url> refs/heads/<prefix>*``. Status: ``review`` when
a newer series exists, ``update`` when the channel moved, ``current``
otherwise, ``error`` when the channel is gone. Current and latest are
12-character commits; details: ``channel``, ``head``, ``newest_series``.
Flake inputs with a channel get this row built in (core.py).
"""

from __future__ import annotations

import re
from typing import Any, ClassVar

from ...lockfile import Scope
from ...rules import string
from ..model import Row, item, newest, version_key
from ..upstream import Upstream, github_repo, github_url
from . import Adapter, FieldSpec, PlanContext, PlanError, Request, url

SERIES = re.compile(r"(?P<prefix>.*?)\d{2}\.\d{2}")


class ChannelHead(Adapter):
    name = "channel-head"
    VERSIONED = False
    FIELDS: ClassVar[dict[str, FieldSpec]] = {
        "url": FieldSpec(url),
        "prefix": FieldSpec(string),
        "channel_field": FieldSpec(string, default="channel"),
        "revision_field": FieldSpec(string, default="revision"),
    }

    def resolve(self, ctx: PlanContext, scope: Scope, pin: Any, request: Request) -> None:
        if not isinstance(pin, dict):
            raise PlanError("no pin object: declare 'at'")
        channel = pin.get(self.values["channel_field"])
        revision = pin.get(self.values["revision_field"])
        if not isinstance(channel, str) or not channel:
            raise PlanError(f"the pin has no channel field {self.values['channel_field']!r}")
        if not isinstance(revision, str) or not revision:
            raise PlanError(f"the pin has no revision field {self.values['revision_field']!r}")
        prefix = self.values["prefix"]
        if prefix is None:
            match = SERIES.fullmatch(channel)
            if match is None:
                raise PlanError(f"cannot derive the series prefix of channel {channel!r}; declare 'prefix'")
            prefix = match["prefix"]
        repository = self.values["url"]
        if repository is None:
            reference = pin.get("reference")
            repo = github_repo(reference) if isinstance(reference, str) and reference.startswith("github:") else None
            if repo is None:
                raise PlanError(f"the pin's reference {reference!r} is not a GitHub reference; declare 'url'")
            repository = github_url(repo)
        request.current = revision[:12]
        request.values.update(channel=channel, revision=revision, prefix=prefix, url=repository)

    def default_source(self, request: Request) -> str:
        return request.values["url"]

    def fetch(self, request: Request, upstream: Upstream) -> list[Row]:
        values = request.values
        prefix, channel = values["prefix"], values["channel"]
        heads = upstream.remote_heads(values["url"], f"refs/heads/{prefix}*")
        series = [name for name in heads if re.fullmatch(rf"{re.escape(prefix)}\d{{2}}\.\d{{2}}", name)]
        newest_series = newest(series)
        head = heads.get(channel)
        if head is None:
            status = "error"
        elif newest_series and version_key(newest_series) > version_key(channel):
            status = "review"
        elif head != values["revision"]:
            status = "update"
        else:
            status = "current"
        return [
            item(
                request.id,
                self.name,
                request.current,
                head[:12] if head else None,
                status,
                self.source_of(request),
                channel=channel,
                head=head,
                newest_series=newest_series,
                note=request.note,
            )
        ]
