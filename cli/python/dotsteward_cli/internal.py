"""``python3 -m dotsteward_cli.internal``: the primitives for bash.

The bash code of the framework calls this through ``ds_internal`` of
``cli/lib/python.sh``; Python code imports the modules themselves. It is no
command of the CLI and may change with the framework. Exit status: 0 done, 1
refused or failed, 2 usage error, unless a subcommand says otherwise.

    version-compare LEFT RIGHT   prints -1, 0 or 1 (dotsteward_cli.versions)
    state-root [--instance DIR]  prints the state root (config.state_root)
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence


def _version_compare(args: argparse.Namespace) -> int:
    from dotsteward_cli import versions

    print(versions.compare(args.left, args.right))
    return 0


def _state_root(args: argparse.Namespace) -> int:
    from dotsteward_cli import config

    if args.instance is None:
        print(config.discovered_state_root())
    else:
        print(config.state_root(config.load_instance(args.instance)))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dotsteward_cli.internal", description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)

    compare = commands.add_parser("version-compare", allow_abbrev=False)
    compare.add_argument("left")
    compare.add_argument("right")
    compare.set_defaults(run=_version_compare)

    root = commands.add_parser("state-root", allow_abbrev=False)
    root.add_argument("--instance")
    root.set_defaults(run=_state_root)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    from dotsteward_cli import config

    args = _parser().parse_args(argv)
    try:
        code: int = args.run(args)
    except config.DotstewardError as error:
        print("\n".join(error.lines()), file=sys.stderr)
        return 1
    return code


if __name__ == "__main__":
    sys.exit(main())
