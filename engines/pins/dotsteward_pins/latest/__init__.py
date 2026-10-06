"""``dotsteward pins latest``: research the newest stable upstream versions
of an instance's pins and write a report; nothing else is changed.

Modules: ``model`` (rows, the status model, ordering, the report),
``upstream`` (HTTP, ``gh`` and ``git ls-remote`` access), ``templates``
(the ``{version}`` templates of release URLs and asset names),
``adapters`` (one module per adapter and the declaration machinery),
``core`` (the built-in rows) and ``runner`` (planning, parallel jobs,
error isolation, output).

Rows come from the ``pins.latest`` declarations of the enabled components
(read from the manifest mirrors) and from built-in rows derived from the
lock files: every flake input with a channel (``channel-head``) or a
version (``github-release``), the Nix installer (``nix-release``), the
vendored skills (``skill-source``), packages that follow nixpkgs
(``follows``, with ``--all``) and the ``framework`` row. A declared row
replaces the built-in row with the same id.
"""
