#!/usr/bin/env bash
# summary: Open a maintain transaction (maintain begin), which dotsteward apply finishes
#
# The engine is cli/python/dotsteward_cli/apply.py (docs/apply.md). The file of a
# command written in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.apply maintain "$@"
