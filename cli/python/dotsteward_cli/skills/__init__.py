"""Tracking of the user's own skills: ``dotsteward skills``.

A skill is the user's own when its lock revision is a repo-owned sentinel
(``same-as-instance-checkout`` or ``[compat] repo_owned_revision``). Such a skill
has three digests: the normal form of the local copy (``normal``), the lock of the
repository, and what this machine last had in sync (``state``, ``base.json``).
``threeway`` turns them into one decision, which `agents install`, `agents check`
and ``skills status`` share.

``hook`` runs inside an agent's session, so nothing here imports at module level
what the path without a change does not need.
"""
