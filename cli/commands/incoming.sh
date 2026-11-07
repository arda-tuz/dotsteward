#!/usr/bin/env bash
# summary: Answer what other machines changed: install it here, ask later, or never on this machine
#
# The engine is cli/python/dotsteward_cli/incoming.py. The file of a command written
# in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.incoming "$@"
