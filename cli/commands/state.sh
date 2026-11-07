#!/usr/bin/env bash
# summary: Record the state this machine observes on its own state branch, push it, fetch and show the state of every machine
#
# The engine is cli/python/dotsteward_cli/state.py. The file of a command written
# in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.state "$@"
