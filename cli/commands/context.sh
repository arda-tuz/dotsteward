#!/usr/bin/env bash
# summary: Print the facts of the instance on this machine (--json for skills)
#
# Usage: dotsteward context [--json]
#
# The instance, the check and runtime identity, state record paths, profiles,
# gate parameters, commit rules, protected paths, skill overlays, components
# with their methods, settings targets and commands, the settings buffer's
# target names and entry ids (never values), instance skills, the framework
# and its upstream, and the platform (schema/context.schema.json).
# The engine is cli/python/dotsteward_cli/context.py, run with the python3
# first on PATH (the package puts its own python there). Exit 0, or 1.
set -Eeuo pipefail

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
  printf '[dotsteward] ERROR: context needs python3 on PATH\n' >&2
  exit 1
fi

PYTHONPATH=$root/cli/python PYTHONDONTWRITEBYTECODE=1 \
  exec python3 -s -P -m dotsteward_cli.context "$@"
