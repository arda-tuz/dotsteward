#!/usr/bin/env bash
# summary: Notice the system packages changed outside dotsteward, check the tracked components they reach and record the state of this machine
#
# The engine is cli/python/dotsteward_cli/observe.py. The file of a command written
# in Python (docs/python.md). The path unit dotsteward-observe.path of the generation
# (modules/core/observer.nix) starts it when dpkg writes its status file.
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.observe "$@"
