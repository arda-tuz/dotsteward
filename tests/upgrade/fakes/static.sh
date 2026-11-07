#!/usr/bin/env bash
# summary: Fake static of the upgrade tests
printf 'static %s\n' "$*" >>"$UP_LOG"
# A hook: what happens elsewhere while the gate runs, and a place to press Ctrl-C.
if [[ -e $UP_CONTROL/during-gate ]]; then
  bash "$UP_CONTROL/during-gate"
fi
[[ ! -e $UP_CONTROL/static-red ]]
