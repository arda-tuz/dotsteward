"""``dotsteward skills``: the command line of skill tracking.

Parsing stays out of the way of a hook: ``skills hook`` reads its own arguments,
without argparse, because argparse exits 2 on anything it does not know and a
status 2 from a Stop hook would keep the agent from stopping.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments[:1] == ["hook"]:
        from dotsteward_cli.skills import hook

        return hook.main(arguments[1:])
    from dotsteward_cli.skills import commands

    return commands.main(arguments)


if __name__ == "__main__":
    sys.exit(main())
