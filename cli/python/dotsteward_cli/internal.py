"""``python3 -m dotsteward_cli.internal``: the primitives for bash.

The bash code of the framework calls this through ``ds_internal`` of
``cli/lib/python.sh``; Python code imports the modules themselves. It is no
command of the CLI and may change with the framework. Exit status: 0 done, 1
refused or failed, 2 usage error, unless a subcommand says otherwise.

    version-compare LEFT RIGHT   prints -1, 0 or 1 (dotsteward_cli.versions)
    state-root [--instance DIR]  prints the state root (config.state_root)
    atomic-write PATH [--mode M] [--parents]
                                 writes standard input to PATH (atomic.atomic_write)
"""

from __future__ import annotations

import argparse
import re
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


def _atomic_write(args: argparse.Namespace) -> int:
    from dotsteward_cli import atomic, config

    mode = None
    if args.mode is not None:
        if not re.fullmatch(r"0?[0-7]{3}", args.mode):
            raise config.DotstewardError(f"invalid mode: {args.mode}")
        mode = int(args.mode, 8)
    try:
        atomic.atomic_write(args.path, sys.stdin.buffer.read(), mode=mode, parents=args.parents)
    except OSError as error:
        raise config.DotstewardError(f"cannot write {args.path}: {error.strerror}") from error
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

    write = commands.add_parser("atomic-write", allow_abbrev=False)
    write.add_argument("path")
    write.add_argument("--mode")
    write.add_argument("--parents", action="store_true")
    write.set_defaults(run=_atomic_write)
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
