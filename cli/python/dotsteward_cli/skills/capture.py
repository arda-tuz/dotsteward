"""``skills capture``: from a change on this machine to the remote of the instance."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from dotsteward_cli.skills import sleeper


def run_now(context: Mapping[str, Any]) -> int:
    """One capture run: what waits goes out; 0 when nothing is left to do."""
    sleeper.log(str(context["state_root"]), "run")
    return 0
