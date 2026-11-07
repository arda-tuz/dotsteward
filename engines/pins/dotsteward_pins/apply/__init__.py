"""``dotsteward pins apply``: moves the pins of an instance to the rows of ``pins
latest``, without an agent's judgment. It writes the working tree only: committing,
validating and publishing are its caller's.

``plan`` routes every row (a group that moves, a review item, a report line),
``tools`` runs the external programs, ``writers`` and ``skills`` move one group
each, ``runner`` holds the run together. A group moves as a whole or restores every
byte it touched, and the other groups go on.

What is written is read from the declarations the instance already has, never from
a list of components: the fields of a download pin from its ``download-pin`` rule,
a bundle from its ``npm-bundle`` rule, a requirements file from its ``text-guard``
rule, the build pins from their ``*_nix_sha256`` fields. A row none of them explains
has no writer and becomes a review item: the writer never guesses.
"""
