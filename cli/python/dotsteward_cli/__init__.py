"""The base of the Python package of the dotsteward command line interface
(docs/python.md): the commands written in Python and the primitives that the
commands and the engines share.

The modules run with the interpreter of the CLI package (the instance's
python with tomlkit) and only the standard library otherwise:

- ``config``: the ``workstation.toml`` reader, the same validation and
  resolved value as ``lib/config.nix``, the ``DS_*`` exporter that
  ``cli/lib/config.sh`` evaluates, and the one state root.
- ``context``, ``doctor``, ``init``: the commands of those names.
- ``versions``: the one version order.
- ``tomlfile``: the one TOML reader.
- ``atomic``: atomic file writes.
- ``locks``: file locks and the instance lock.
- ``report``: run reports and ``review.json``.
- ``procs``: child processes a command waits for to the end.
- ``internal``: the primitives for bash (``cli/lib/python.sh``).
"""
