#!/usr/bin/env bash
# summary: Fake scan of the upgrade tests: a finding when the tree holds a file named FINDING
printf 'scan %s %s\n' "$*" "$PWD" >>"$UP_LOG"
if [[ -n $(find . -name FINDING -print -quit) ]]; then
  printf 'finding: FINDING\n'
  exit 1
fi
