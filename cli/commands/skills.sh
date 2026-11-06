#!/usr/bin/env bash
# summary: Track the user's own skills, and report what the instance means for this machine
#
# The engine is cli/python/dotsteward_cli/skills. The file of a command written
# in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.skills.cli "$@"
