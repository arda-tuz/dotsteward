"""``dotsteward skills``: the command line of skill tracking."""

from __future__ import annotations

import sys
from collections.abc import Sequence


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    from dotsteward_cli.skills import commands

    return commands.main(arguments)


if __name__ == "__main__":
    sys.exit(main())
