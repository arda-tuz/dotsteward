#!/usr/bin/env bash
# summary: Bring this machine and the shared lock to the newest stable versions, with one command
#
# The engine is cli/python/dotsteward_cli/upgrade (docs/upgrade.md). The file of a
# command written in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.upgrade.cli "$@"
