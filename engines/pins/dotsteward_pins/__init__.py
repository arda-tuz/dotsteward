"""The dotsteward pins engine (SPEC 5): consistency checks and derived
mirror synchronization of an instance's lock files (``versions.lock.json``
and the skills lock), driven by declarative rules, plus the upstream
research report (``latest``).

Modules: ``cli`` (command line), ``instance`` (discovery, configuration,
manifest mirrors, git and nix calls), ``lockfile`` (serializer, atomic
writes, lock paths and templates), ``digest`` (file and directory
digests), ``checker`` (assertion accumulator), ``rules`` (one module per
rule kind) and ``latest`` (the research runner and its adapters).

Standard library only, so ``check`` runs offline in the Nix build sandbox.
"""
