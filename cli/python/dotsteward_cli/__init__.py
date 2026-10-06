"""Python engines of the dotsteward command line interface.

The modules run with the interpreter of the CLI package (the instance's
python with tomlkit, F8) and only the standard library otherwise:

- ``config``: the ``workstation.toml`` reader, the same validation and
  resolved value as ``lib/config.nix``, and the ``DS_*`` exporter that
  ``cli/lib/config.sh`` evaluates.
"""
