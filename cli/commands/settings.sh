#!/usr/bin/env bash
# summary: Sync tracked application settings with the instance's settings buffer
#
# Usage: dotsteward settings [--repo DIR] [--home DIR] [--state-dir DIR]
#                            [--targets-file FILE] <command> [ARG...]
#
# Commands: status [--json], apply, flush, resolve ID --local|--remote,
# reconcile, verify, track, track-file, untrack, validate. Run
# `dotsteward settings --help` or `dotsteward settings <command> --help` for
# the details. Exit codes: 0 ok, 1 verify found entries that did not
# converge, 2 error, 3 flush left entries waiting for a decision.
#
# The engine is engines/local-maintained-files/local_maintained_files.py,
# run with the python3 first on PATH (the package puts its own python with
# tomlkit there). The generation's local-maintained-files command is this
# command with the generation's targets file, checkout and state directory.
set -Eeuo pipefail

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
engine_dir=$root/engines/local-maintained-files

if ! command -v python3 >/dev/null 2>&1; then
  printf '[dotsteward] ERROR: settings needs python3 with tomlkit on PATH\n' >&2
  exit 2
fi

PYTHONPATH=$engine_dir:$root/cli/python PYTHONDONTWRITEBYTECODE=1 \
  exec python3 -s -P -m local_maintained_files "$@"
