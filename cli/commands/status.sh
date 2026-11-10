#!/usr/bin/env bash
# summary: One read-only overview of this machine and its instance, offline
#
# The engine is cli/python/dotsteward_cli/status.py (docs/track.md). The file of a
# command written in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.status "$@"
