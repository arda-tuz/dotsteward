#!/usr/bin/env bash
# summary: Report what the skills, plugins and components of the instance mean for this machine
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.machine "$@"
