#!/usr/bin/env bash
# summary: Name this machine and bring its host file to the remote (init, publish, show, list, rename, producer, check)
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.host "$@"
