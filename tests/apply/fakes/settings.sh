#!/usr/bin/env bash
# summary: Fake settings of the apply tests: the status of the buffer
#
# $UP_CONTROL/settings.json: the document of `status --json`, else no entries.
set -euo pipefail
printf 'settings %s\n' "$*" >>"$UP_LOG"
if [[ -e $UP_CONTROL/settings.json ]]; then
  cat -- "$UP_CONTROL/settings.json"
else
  printf '{"schema_version": 1, "published_available": true, "repo_last_change": null, "entries": []}\n'
fi
