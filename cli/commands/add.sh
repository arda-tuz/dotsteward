#!/usr/bin/env bash
# summary: Track a component: write it into the intent and publish it with dotsteward apply
#
# The engine is cli/python/dotsteward_cli/track.py (docs/track.md). The file of a
# command written in Python (docs/python.md).
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.track add "$@"
