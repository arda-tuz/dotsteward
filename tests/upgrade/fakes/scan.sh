#!/usr/bin/env bash
# summary: Fake scan of the upgrade tests: a finding when the tree holds a file named FINDING
printf 'scan %s %s\n' "$*" "$PWD" >>"$UP_LOG"
if [[ -n $(find . -name SCAN-FAILS -print -quit) ]]; then
  printf '[dotsteward] ERROR: the scan failed\n' >&2
  exit 1
fi
if [[ -n $(find . -name FINDING -print -quit) ]]; then
  printf 'finding: FINDING\n'
  exit 1
fi
