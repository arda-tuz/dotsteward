#!/usr/bin/env bash
# summary: Check the health of the instance on this machine (--redact to share)
#
# Usage: dotsteward doctor [--json] [--redact]
#
# Runs read-only health checks on top of `dotsteward context`: the
# configuration, the runtime identity, Nix, the launcher cache, the
# .dotsteward mirrors, the last built generation's manifest and the age of
# the gate memo. --redact replaces home directories, usernames, the hostname,
# the remote and private names with <redacted> so the report can be shared.
# The engine is cli/python/dotsteward_cli/doctor.py, run with the python3
# first on PATH. Exit 0, or 1 when a check fails or for a usage error.
set -Eeuo pipefail

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
  printf '[dotsteward] ERROR: doctor needs python3 on PATH\n' >&2
  exit 1
fi

PYTHONPATH=$root/cli/python PYTHONDONTWRITEBYTECODE=1 \
  exec python3 -s -P -m dotsteward_cli.doctor "$@"
