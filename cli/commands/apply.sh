#!/usr/bin/env bash
# summary: Finish a maintain transaction in one command: gate, commit, activate, E2E, publish
#
# The engine is cli/python/dotsteward_cli/apply.py (docs/apply.md). The file of a
# command written in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.apply apply "$@"
